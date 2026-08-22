#!/bin/bash
# encode-pipeline.sh — Basal ganglia habit encoding pipeline
#
# Pipeline:
# 1. Preprocess transcripts → habit-signals.jsonl
# 2. Score signals using rule-based heuristics (habit / procedure /
#    suppression / reinforcement candidates)
# 3. Write pending-habits.json for LLM classification
# 4. Advance the watermark so signals aren't reprocessed
# 5. Sync state (BASAL_GANGLIA_STATE.md + brain-dashboard.html)
# 6. Spawn (or print instructions for) the classification sub-agent
#
# Usage: ./scripts/encode-pipeline.sh [--no-spawn]
#
# Environment:
#   WORKSPACE - OpenClaw workspace (default: ~/.hermes/workspace)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNALS_FILE="$WORKSPACE/memory/habit-signals.jsonl"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
PENDING_FILE="$WORKSPACE/memory/pending-habits.json"
NO_SPAWN="${1:-}"

echo "🎯 BASAL GANGLIA ENCODING PIPELINE"
echo "==================================="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ No habit state found at $STATE_FILE"
    echo "   Run install.sh first."
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# STEP 1: Preprocess
# ═══════════════════════════════════════════════════════════════
echo "📥 Step 1: Preprocessing..."
WORKSPACE="$WORKSPACE" "$SKILL_DIR/scripts/preprocess-habits.sh"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 2: Check for signals
# ═══════════════════════════════════════════════════════════════
if [ ! -f "$SIGNALS_FILE" ]; then
    echo "❌ No signals file. Done."
    exit 0
fi

SIGNAL_COUNT=$(wc -l < "$SIGNALS_FILE" | tr -d ' ')
echo "📊 Step 2: Found $SIGNAL_COUNT signals"

if [ "$SIGNAL_COUNT" -eq 0 ]; then
    echo "✅ No new signals. Done."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: Score signals and prepare pending-habits.json
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🔄 Step 3: Scoring signals for habit/procedure/suppression candidates..."

export SIGNALS_FILE STATE_FILE PENDING_FILE

python3 << 'PYTHON'
import json
import os
import re
from datetime import datetime, timezone

SIGNALS_FILE = os.environ["SIGNALS_FILE"]
STATE_FILE = os.environ["STATE_FILE"]
PENDING_FILE = os.environ["PENDING_FILE"]

# Load signals
signals = []
with open(SIGNALS_FILE, 'r') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                signals.append(json.loads(line))
            except json.JSONDecodeError:
                pass

# Load existing state
with open(STATE_FILE) as f:
    state = json.load(f)

habits = state.get('habits', [])
procedures = state.get('procedures', [])
suppressions = state.get('suppressions', [])

# ── Scoring heuristics ──────────────────────────────────────────────────
SKIP_PATTERNS = [
    r'^\[?system:',
    r'^heartbeat',
    r'^(ok|okay|yes|no|sure|thanks|thank you|got it|sounds good|will do)\.?$',
    r'^\[message_id:',
    r'^cron:',
    r'^no_reply$',
]

# Negative-reinforcement / correction language → suppression candidate
SUPPRESSION_PATTERNS = [
    r"\bdon'?t (?:ever |do that |do this )?",
    r'\bnever (?:do|use|suggest|say|try)\b',
    r'\bstop (?:doing|using|suggesting)\b',
    r"\bplease (?:don'?t|avoid|stop)\b",
    r'\bavoid (?:doing|using|suggesting)?\b',
    r"\bthat'?s (?:wrong|not right|incorrect)\b",
    r'\bnot what i asked\b',
    r'\binstead of\b',
    r'\bnext time,? (?:please |don\'?t )',
    r'\bshould have\b',
]

# Explicit instruction / preference language → habit candidate
HABIT_PATTERNS = [
    r'\balways\b',
    r'\bfrom now on\b',
    r'\bby default\b',
    r'\bevery time\b',
    r'\bmake (?:it|this) a habit\b',
    r'\bi (?:always|prefer|like|want you to|need you to)\b',
    r'\bmake sure (?:you|to)\b',
    r'\bremember to\b',
    r'\bwhenever\b.*\b(?:please|make sure|do)\b',
]

# Multi-step workflow language → procedure candidate
PROCEDURE_PATTERNS = [
    r'(?:^|\n)\s*[1-9]\.\s',          # numbered steps
    r'\b(?:first|second|third|finally|then|next)\b.*\b(?:then|finally|next|after)\b',
    r'→|->',
]


def score_signal(text, role):
    text_lower = text.lower()

    for pat in SKIP_PATTERNS:
        if re.search(pat, text_lower):
            return 0.0, 'skip', None

    if len(text) < 12:
        return 0.0, 'too-short', None

    # Suppressions first — corrections are high-value, low-volume signals
    for pat in SUPPRESSION_PATTERNS:
        if re.search(pat, text_lower):
            return 0.80, 'correction', 'suppression'

    # Explicit habit / preference instructions
    for pat in HABIT_PATTERNS:
        if re.search(pat, text_lower):
            return 0.80, 'explicit-preference', 'habit'

    # Multi-step procedures — count pattern hits, need at least 2 step markers
    step_markers = len(re.findall(r'(?:^|\n)\s*[1-9]\.\s', text))
    arrow_markers = text.count('→') + text.count('->')
    if step_markers >= 2 or arrow_markers >= 2:
        return 0.65, 'multi-step-workflow', 'procedure'

    # General "I did X" routine descriptions from the assistant — low
    # confidence on their own, but candidates for reinforcement if they
    # match an existing habit/procedure (checked below).
    if role == 'assistant' and len(text) > 60:
        if any(x in text_lower for x in [
            'i checked', 'i ran', 'i started by', 'i first', 'before doing',
            'as usual', 'as always', 'following the usual', 'per the usual',
        ]):
            return 0.55, 'routine-description', 'habit'
        return 0.35, 'general-assistant', 'habit'

    if role == 'user' and len(text) > 100:
        return 0.40, 'substantial-user-input', 'habit'

    return 0.0, 'skip', None


def normalize_words(text):
    return set(re.findall(r'[a-z]{3,}', text.lower()))


def best_match(text, items, fields):
    """Return (id, overlap_ratio) for the best word-overlap match, or (None, 0)."""
    sig_words = normalize_words(text)
    if not sig_words:
        return None, 0.0
    best_id, best_ratio = None, 0.0
    for item in items:
        item_text = ' '.join(str(item.get(f, '')) for f in fields)
        if isinstance(item.get('steps'), list):
            item_text += ' ' + ' '.join(item['steps'])
        if isinstance(item.get('tags'), list):
            item_text += ' ' + ' '.join(item['tags'])
        item_words = normalize_words(item_text)
        if not item_words:
            continue
        overlap = len(sig_words & item_words)
        union = len(sig_words | item_words)
        ratio = overlap / union if union else 0.0
        if ratio > best_ratio:
            best_ratio, best_id = ratio, item.get('id')
    return best_id, best_ratio


SIMILARITY_THRESHOLD = 0.35

pending = []
skipped = 0
reinforcement_candidates = 0
today = datetime.now(timezone.utc).strftime('%Y-%m-%d')

for sig in signals:
    text = sig.get('text', '')
    role = sig.get('role', 'user')
    ts = sig.get('timestamp', '')

    score, reason, suggested_type = score_signal(text, role)

    if score <= 0 or suggested_type is None:
        skipped += 1
        continue

    entry = {
        'signal_id': sig.get('id', ts),
        'timestamp': ts,
        'role': role,
        'raw_text': text[:600],
        'score': round(score, 2),
        'reason': reason,
        'suggested_type': suggested_type,
        'created': today,
    }

    # Check for an existing match to reinforce instead of creating new
    if suggested_type == 'habit':
        match_id, ratio = best_match(text, habits, ['cue', 'routine', 'reward'])
        if ratio >= SIMILARITY_THRESHOLD:
            entry['suggested_type'] = 'reinforcement'
            entry['item_type'] = 'habit'
            entry['similar_id'] = match_id
            entry['similarity'] = round(ratio, 2)
            reinforcement_candidates += 1
    elif suggested_type == 'procedure':
        match_id, ratio = best_match(text, procedures, ['name'])
        if ratio >= SIMILARITY_THRESHOLD:
            entry['suggested_type'] = 'reinforcement'
            entry['item_type'] = 'procedure'
            entry['similar_id'] = match_id
            entry['similarity'] = round(ratio, 2)
            reinforcement_candidates += 1
    elif suggested_type == 'suppression':
        match_id, ratio = best_match(text, suppressions, ['pattern', 'reason'])
        if ratio >= SIMILARITY_THRESHOLD:
            entry['suggested_type'] = 'reinforcement'
            entry['item_type'] = 'suppression'
            entry['similar_id'] = match_id
            entry['similarity'] = round(ratio, 2)
            reinforcement_candidates += 1

    pending.append(entry)

with open(PENDING_FILE, 'w') as f:
    json.dump({"pending": pending, "created": today}, f, indent=2)

print(f"   Total signals:          {len(signals)}")
print(f"   Pending classification: {len(pending)}")
print(f"   ↳ reinforcement matches: {reinforcement_candidates}")
print(f"   Skipped (low signal):   {skipped}")
PYTHON

# ═══════════════════════════════════════════════════════════════
# STEP 4: Advance watermark (these signals have been queued)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🔖 Step 4: Advancing watermark..."
"$SKILL_DIR/update-watermark.sh" --from-signals

# ═══════════════════════════════════════════════════════════════
# STEP 5: Sync state + dashboard
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🔄 Step 5: Syncing state..."
WORKSPACE="$WORKSPACE" "$SKILL_DIR/scripts/sync-state.sh" || true

# ═══════════════════════════════════════════════════════════════
# STEP 6: Report + hand off to classification sub-agent
# ═══════════════════════════════════════════════════════════════
PENDING_COUNT=$(PENDING_FILE="$PENDING_FILE" python3 -c "import os
import json; d=json.load(open(os.environ['PENDING_FILE'])); print(len(d.get('pending',[])))" 2>/dev/null || echo "0")

echo ""
if [ "$PENDING_COUNT" -eq 0 ]; then
    echo "✅ No habit signals need classification. Done."
    rm -f "$PENDING_FILE"
    exit 0
fi

echo "📝 $PENDING_COUNT signals pending classification in:"
echo "   $PENDING_FILE"

if [ "$NO_SPAWN" = "--no-spawn" ]; then
    echo "⏭️  Skipping spawn (--no-spawn flag)"
    exit 0
fi

echo ""
echo "✅ Pipeline phase 1 complete. Sub-agent will classify pending signals."
echo ""
echo "To complete manually:"
echo "  1. Read $PENDING_FILE"
echo "  2. Classify each entry per prompts/encode-habits.md"
echo "  3. Apply results with reinforce-habit.sh"
echo "  4. rm $PENDING_FILE"
echo "  5. ./scripts/sync-state.sh"
