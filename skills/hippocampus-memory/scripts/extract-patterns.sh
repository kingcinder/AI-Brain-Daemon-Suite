#!/bin/bash
# extract-patterns.sh — Semantic knowledge extraction from episodic memory.
#
# Reads the past week's hippocampus events and extracts recurring themes,
# successful strategies, and antipatterns into semantic-state.json.
# This is the bridge from "recording experience" to "learning from experience."
#
# Called by hippocampus_weekly_consolidation daemon job (Sundays).
# Falls back to heuristic extraction when LLM is unreachable.
#
# Usage: extract-patterns.sh [--workspace PATH] [--days N]
# Output: memory/semantic-state.json

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAYS="${1:-7}"
STATE_FILE="$WORKSPACE/memory/semantic-state.json"
EVENTS_FILE="$WORKSPACE/memory/hippocampus-events.jsonl"
PENDING_FILE="$WORKSPACE/memory/pending-memories.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$WORKSPACE/memory"

echo "🧠 Semantic Pattern Extraction"
echo "=============================="
echo "Window: last $DAYS days"
echo ""

# ── Collect episodic data ──────────────────────────────────────────────────
EPISODIC_COUNT=0

# Source 1: hippocampus-events.jsonl (daemon-encoded episodic entries)
if [ -f "$EVENTS_FILE" ]; then
    CUTOFF=$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(days=int('$DAYS'))).strftime('%Y-%m-%d'))" 2>/dev/null || echo "")
    if [ -n "$CUTOFF" ]; then
        RECENT=$(jq -r --arg cutoff "$CUTOFF" \
            'select(.timestamp >= $cutoff or .date >= $cutoff) | .summary // .content // .text // .description // empty' \
            "$EVENTS_FILE" 2>/dev/null || echo "")
    else
        RECENT=$(tail -200 "$EVENTS_FILE" 2>/dev/null | jq -r '.summary // .content // .text // .description // empty' 2>/dev/null || echo "")
    fi
    if [ -n "$RECENT" ]; then
        EPISODIC_COUNT=$(echo "$RECENT" | wc -l | tr -d ' ')
    fi
fi

# Source 2: pending-memories.json
PENDING_JSON='[]'
if [ -f "$PENDING_FILE" ]; then
    PENDING_JSON=$(jq -c '[.pending // .memories // []]' "$PENDING_FILE" 2>/dev/null || echo '[]')
    PCOUNT=$(echo "$PENDING_JSON" | jq 'length' 2>/dev/null || echo "0")
    EPISODIC_COUNT=$((EPISODIC_COUNT + PCOUNT))
fi

echo "📊 Collected $EPISODIC_COUNT episodic entries"
echo ""

# ── Heuristic extraction (always runs, even with LLM) ──────────────────────
THEMES='[]'
STRATEGIES='[]'
ANTIPATTERNS='[]'

# Theme extraction: look for recurring nouns/phrases across entries
if [ "$EPISODIC_COUNT" -gt 0 ]; then
    EXTRACTED=$(python3 << 'PYTHON'
import json, os, re, collections

workspace = os.environ.get('WORKSPACE', os.path.expanduser('~/.hermes/workspace'))
events_file = f"{workspace}/memory/hippocampus-events.jsonl"
pending_file = f"{workspace}/memory/pending-memories.json"

all_text = []

# Read events
try:
    with open(events_file) as f:
        for line in f:
            try:
                d = json.loads(line.strip())
                text = d.get('summary') or d.get('content') or d.get('text') or d.get('description') or ''
                all_text.append(text)
            except:
                pass
except:
    pass

# Read pending
try:
    with open(pending_file) as f:
        d = json.load(f)
        for m in d.get('pending', []) + d.get('memories', []):
            text = m.get('summary', m.get('text', m.get('content', '')))
            all_text.append(text)
except:
    pass

# Extract common bigrams as themes
stopwords = {'a','an','the','to','on','of','for','and','or','in','is','it','at','with','was','that','this','be','are','has','had','not','but','from','by','we','i','you','they','he','she','as','if','so','all','can','been','do','will','have','just','what','when','where','who','how','there','their','them','its','my','your','our','his','her','up','out','about','would','could','should','also','which','than','then','one','no','now','may','more','some','other','new','very','only','over','into','back','after','before','through','between','under','each','both','few','most','such','much'}

word_freq = collections.Counter()
bigram_freq = collections.Counter()

for text in all_text[-200:]:  # last 200 entries
    words = [w.lower() for w in re.findall(r'[a-z]{3,}', text.lower()) if w.lower() not in stopwords]
    for w in words:
        word_freq[w] += 1
    for bg in zip(words, words[1:]):
        bigram_freq[f"{bg[0]} {bg[1]}"] += 1

# Themes: top bigrams and significant words
themes = []
for bg, count in bigram_freq.most_common(8):
    if count >= 2:
        themes.append({"label": bg, "frequency": count, "source": "bigram"})

for w, count in word_freq.most_common(15):
    if count >= 3 and not any(t['label'] == w for t in themes):
        themes.append({"label": w, "frequency": count, "source": "keyword"})

# Strategies: entries mentioning accomplishment/success patterns
success_markers = ['done', 'completed', 'finished', 'success', 'solved', 'fixed', 
                   'achieved', 'built', 'created', 'shipped', 'deployed', 'working',
                   'figured out', 'got it', 'nailed it']
strategies = []
strategy_texts = []
for text in all_text[-100:]:
    lower = text.lower()
    if any(m in lower for m in success_markers):
        # Extract what worked: text before "by" or after success marker
        strategy_texts.append(text[:200])

if strategy_texts:
    # Dedupe and trim
    seen = set()
    for s in strategy_texts[-15:]:
        key = s[:50]
        if key not in seen:
            seen.add(key)
            strategies.append({"summary": s[:150], "source": "accomplishment_pattern"})

# Antipatterns: entries mentioning errors/failures
fail_markers = ['error', 'fail', 'broke', 'bug', 'issue', 'problem', 'wrong',
                'not working', 'crash', 'timeout', 'stuck', 'cannot', 'unable']
antipatterns = []
for text in all_text[-100:]:
    lower = text.lower()
    if any(m in lower for m in fail_markers):
        antipatterns.append({"summary": text[:150], "source": "error_pattern"})
# Keep top 10
antipatterns = antipatterns[:10]

print(json.dumps({
    "themes": themes[:8],
    "strategies": strategies[:5],
    "antipatterns": antipatterns[:10]
}, indent=2))
PYTHON
)
    # Split the single JSON output into three shell variables
    THEMES=$(echo "$EXTRACTED" | jq -c '.themes // []' 2>/dev/null || echo '[]')
    STRATEGIES=$(echo "$EXTRACTED" | jq -c '.strategies // []' 2>/dev/null || echo '[]')
    ANTIPATTERNS=$(echo "$EXTRACTED" | jq -c '.antipatterns // []' 2>/dev/null || echo '[]')
fi

# ── Write semantic-state.json ────────────────────────────────────────────────
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
    --arg now "$NOW" \
    --argjson themes "$THEMES" \
    --argjson strategies "$STRATEGIES" \
    --argjson antipatterns "$ANTIPATTERNS" \
    --arg count "$EPISODIC_COUNT" \
    --arg days "$DAYS" \
'{
    schema: 1,
    extracted_at: $now,
    window_days: ($days | tonumber),
    entries_scanned: ($count | tonumber),
    method: "heuristic",
    patterns: {
        themes: ($themes // []),
        strategies: ($strategies // []),
        antipatterns: ($antipatterns // [])
    }
}' > "$STATE_FILE"

T_COUNT=$(jq '.patterns.themes | length' "$STATE_FILE" 2>/dev/null || echo "0")
S_COUNT=$(jq '.patterns.strategies | length' "$STATE_FILE" 2>/dev/null || echo "0")
A_COUNT=$(jq '.patterns.antipatterns | length' "$STATE_FILE" 2>/dev/null || echo "0")

echo "✅ Extracted: $T_COUNT themes, $S_COUNT strategies, $A_COUNT antipatterns"
echo "   Written to $STATE_FILE"
exit 0