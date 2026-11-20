#!/bin/bash
# encode-pipeline.sh — VTA reward encoding; Juno does the detection
#
# Pipeline:
# 1. Preprocess transcript → reward-signals.jsonl
# 2. Rule-based reward scoring
# 3. Prepare pending signals for Juno's semantic reward detection
#
# Usage: ./encode-pipeline.sh [--no-spawn]
#
# Environment:
#   WORKSPACE - OpenClaw workspace (default: ~/.openclaw/workspace)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNALS_FILE="$WORKSPACE/memory/reward-signals.jsonl"
STATE_FILE="$WORKSPACE/memory/reward-state.json"
PENDING_FILE="$WORKSPACE/memory/pending-rewards.json"
NO_SPAWN="${1:-}"

echo "⭐ VTA REWARD ENCODING PIPELINE"
echo "==============================="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 1: Run preprocess
# ═══════════════════════════════════════════════════════════════
echo "📥 Step 1: Preprocessing reward signals..."
"$SKILL_DIR/scripts/preprocess-rewards.sh"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 2: Check for signals
# ═══════════════════════════════════════════════════════════════
if [ ! -f "$SIGNALS_FILE" ] || [ ! -s "$SIGNALS_FILE" ]; then
    echo "✅ No reward signals to process. Done."
    exit 0
fi

SIGNAL_COUNT=$(wc -l < "$SIGNALS_FILE" | tr -d ' ')
echo "📊 Step 2: Found $SIGNAL_COUNT reward signals"

if [ "$SIGNAL_COUNT" -eq 0 ]; then
    echo "✅ No new signals. Done."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: Rule-based reward scoring + prepare for Juno
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🔄 Step 3: Scoring reward signals..."

# Integrative State Layer: reward-starved dopamine (< 0.4) amplifies intensity
NEURO_DA=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get dopamine 2>/dev/null || echo "0.5")
export NEURO_DA

python3 << 'PYTHON'
import json
import os
import re
from datetime import datetime

WORKSPACE = os.environ.get('WORKSPACE', os.path.expanduser('~/.openclaw/workspace'))
SIGNALS_FILE = f"{WORKSPACE}/memory/reward-signals.jsonl"
STATE_FILE = f"{WORKSPACE}/memory/reward-state.json"
PENDING_FILE = f"{WORKSPACE}/memory/pending-rewards.json"

# Load signals
signals = []
with open(SIGNALS_FILE, 'r') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                signals.append(json.loads(line))
            except:
                pass

# Reward patterns for scoring
reward_patterns = {
    'accomplishment': [
        'done', 'complet', 'finish', 'success', 'works', 'fixed', 'solved', 
        'achieved', 'built', 'created', 'shipped', 'deployed', '✅', '✓',
        'nailed it', 'got it', 'figured out', 'working now'
    ],
    'social': [
        'thank', 'thanks', 'appreciate', 'great job', 'well done', 'nice',
        'love it', 'perfect', 'awesome', 'amazing', 'you rock', 'helpful',
        '👍', '❤️', '🙌', 'proud of you'
    ],
    'creative': [
        'new idea', 'creative', 'design', 'invent', 'novel', 'original',
        'built something', 'made a', 'created a', 'came up with', 'brainstorm'
    ],
    'curiosity': [
        'learned', 'discover', 'found out', 'interesting', 'fascinating',
        'realize', 'understand now', 'aha', 'insight', 'cool finding'
    ],
    'connection': [
        'together', 'teamwork', 'we did', 'our project', 'bonding',
        'relationship', 'trust', 'close', 'partnership', 'collaboration'
    ],
    'competence': [
        'master', 'expert', 'skilled', 'improved', 'better at', 'level up',
        'getting good', 'progress', 'growth', 'leveled up', 'efficient'
    ],
}

def score_reward(text):
    """Detect reward types in text"""
    text_lower = text.lower()
    detected = []
    
    for reward_type, keywords in reward_patterns.items():
        for kw in keywords:
            if kw in text_lower:
                detected.append(reward_type)
                break
    
    return list(set(detected))

def estimate_intensity(text, rewards):
    """Estimate reward intensity 0.0-1.0"""
    excl_count = text.count('!')
    caps_ratio = sum(1 for c in text if c.isupper()) / max(len(text), 1)
    
    base = 0.5
    if excl_count > 0:
        base += min(excl_count * 0.1, 0.3)
    if caps_ratio > 0.3:
        base += 0.2
    if len(rewards) > 1:
        base += 0.1
    
    # Boost for explicit celebration words
    celebration = ['amazing', 'incredible', 'perfect', 'exactly', 'brilliant']
    for word in celebration:
        if word in text.lower():
            base += 0.15
            break
    
    return min(base, 1.0)

# Process signals
pending = []
skipped = 0
today = datetime.now().strftime('%Y-%m-%d')

for sig in signals:
    text = sig.get('text', '')
    role = sig.get('role', 'user')
    sig_id = sig.get('id', '')
    
    # Skip very short messages
    if len(text) < 15:
        skipped += 1
        continue
    
    # Detect rewards
    rewards = score_reward(text)
    
    if not rewards:
        skipped += 1
        continue
    
    intensity = estimate_intensity(text, rewards)
    dopamine = float(os.environ.get('NEURO_DA', '0.5'))
    if dopamine < 0.4:
        intensity *= 1.15   # reward-starved: small wins feel bigger
    
    pending.append({
        "id": sig_id,
        "text": text[:500],
        "role": role,
        "detected_rewards": rewards,
        "estimated_intensity": round(intensity, 2),
        "timestamp": sig.get('timestamp', today)
    })

# Save pending for Juno's analysis — MERGE via the shared conservation
# writer (I3, Gated-Ingress Refactor 2026-11-20): the unconsumed backlog
# is carried over and new entries dedupe by id. This block previously
# dumped a fresh list over pending-rewards.json — the same overwrite
# class that dropped ~3,578 hippocampus signals on 2026-11-20; a live
# 133-entry backlog was in the file when this fix landed.
import subprocess, tempfile
_ws = os.path.dirname(os.path.dirname(os.path.abspath(PENDING_FILE)))
_writer = os.path.join(_ws, 'core', 'gate', 'store_write.py')
if os.path.exists(_writer):
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _tf:
        json.dump(pending, _tf)
        _items = _tf.name
    subprocess.run(['python3', _writer, 'merge-list', '--store', PENDING_FILE,
                    '--list-field', 'pending', '--key', 'id',
                    '--items', _items, '--writer', 'vta-memory/encode-pipeline.sh'],
                   check=True, capture_output=True)
    os.unlink(_items)
    pending = json.load(open(PENDING_FILE)).get('pending', [])
else:
    # Fallback (sandbox trees without the gate library): inline merge.
    _existing = []
    if os.path.exists(PENDING_FILE):
        try:
            _existing = json.load(open(PENDING_FILE)).get('pending', []) or []
        except Exception:
            _existing = []
    _seen = {e.get('id') for e in _existing if isinstance(e, dict)}
    pending = _existing + [e for e in pending if e.get('id') not in _seen]
    with open(PENDING_FILE, 'w') as f:
        json.dump({"pending": pending, "created": today}, f, indent=2)

print(f"   Pending for Juno analysis: {len(pending)}")
print(f"   Skipped (no clear reward): {skipped}")

# Show sample
if pending:
    print(f"\n   Sample detected:")
    for p in pending[:3]:
        print(f"      {p['detected_rewards']}: {p['text'][:60]}...")
PYTHON

# Check if we have pending rewards
PENDING_COUNT=$(python3 -c "import json; d=json.load(open('$PENDING_FILE')); print(len(d.get('pending',[])))" 2>/dev/null || echo "0")

if [ "$PENDING_COUNT" -eq 0 ]; then
    echo ""
    echo "✅ No reward signals need Juno analysis. Updating watermark..."
    "$SKILL_DIR/scripts/update-watermark.sh" --from-signals
    # Sync state
    "$SKILL_DIR/scripts/sync-motivation.sh" 2>/dev/null || true
    exit 0
fi

echo ""
echo "📝 $PENDING_COUNT signals pending Juno reward analysis"

if [ "$NO_SPAWN" = "--no-spawn" ]; then
    echo "⏭️  Skipping spawn (--no-spawn flag)"
    exit 0
fi

echo ""
echo "✅ Pipeline phase 1 complete. Juno will handle reward detection."

# Closed-loop: accomplishment rewards that overlap active PFC goals ⇒
# close the goal as success (ROADMAP M4 feedback arc).
if [ -x "$SKILL_DIR/../../core/executive/record-goal-outcome.sh" ]; then
    PFC="$WORKSPACE/memory/pfc-state.json"
    if [ -f "$PFC" ] && [ -f "$PENDING_FILE" ]; then
        ACTIVE_GOALS=$(jq -r '[.goals[]? | select(.status == "active") | .description] | join("\n")' "$PFC" 2>/dev/null || echo "")
        if [ -n "$ACTIVE_GOALS" ]; then
            while IFS= read -r goal; do
                [ -z "$goal" ] && continue
                # Check if any pending reward text overlaps this goal
                OVERLAP=$(jq -r --arg g "$goal" '[.pending[]? | select(.detected_rewards | contains(["accomplishment","competence"])) | .text] | join(" ")' "$PENDING_FILE" 2>/dev/null)
                if [ -n "$OVERLAP" ]; then
                    for word in $goal; do
                        case "$OVERLAP" in *"$word"*) bash "$SKILL_DIR/../../core/executive/record-goal-outcome.sh" outcome --goal-description "$goal" --outcome success --job vta_encode --evidence "VTA reward detection: accomplishment"; break ;; esac
                    done
                fi
            done <<< "$ACTIVE_GOALS"
        fi
    fi
fi
