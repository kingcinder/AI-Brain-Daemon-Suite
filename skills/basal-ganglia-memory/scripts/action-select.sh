#!/bin/bash
# action-select.sh — Basal-ganglia multi-agent action selection (Initiative 10).
#
# Receives competing candidate actions (from decide.sh / gate.sh) and applies
# per-option habit bias + exploration noise (epsilon-greedy) to pick the
# winner. Losers are recorded as suppressed-with-reason in habit-state.json.
#
# Usage:
#   action-select.sh --options '[{"id":"x","label":"...","score":0.7},...]' [--epsilon 0.1]
# Output: JSON {chosen, adjusted_scores, losers, method}
#
# Environment:
#   WORKSPACE — defaults to ~/.hermes/workspace

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
OPTIONS_JSON='[]'
EPSILON="${EPSILON:-0.1}"
NO_RECORD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --options) OPTIONS_JSON="$2"; shift 2 ;;
    --epsilon) EPSILON="$2"; shift 2 ;;
    --no-record) NO_RECORD=1; shift ;;
    -h|--help) echo "Usage: $0 --options JSON [--epsilon 0.1] [--no-record]"; exit 0 ;;
    *) shift ;;
  esac
done

mkdir -p "$WORKSPACE/memory"

HABIT_FILE=$(mktemp)
OPT_FILE=$(mktemp)
trap 'rm -f "$HABIT_FILE" "$OPT_FILE"' EXIT

if [ -f "$STATE_FILE" ]; then cp "$STATE_FILE" "$HABIT_FILE"; else echo '{"habits":[],"suppressions":[]}' > "$HABIT_FILE"; fi
echo "$OPTIONS_JSON" > "$OPT_FILE"

RESULT=$(HABIT_FILE="$HABIT_FILE" OPT_FILE="$OPT_FILE" EPSILON="$EPSILON" NO_RECORD="$NO_RECORD" python3 << 'PYTHON'
import json, os, random, re, copy

habit_file = os.environ['HABIT_FILE']
opt_file = os.environ['OPT_FILE']
epsilon = float(os.environ['EPSILON'])
no_record = os.environ.get('NO_RECORD', '0') == '1'
workspace = os.environ.get('WORKSPACE', os.path.expanduser('~/.hermes/workspace'))
state_file = f"{workspace}/memory/habit-state.json"

with open(opt_file) as f:
    options = json.load(f)
with open(habit_file) as f:
    habit_state = json.load(f)

habits = habit_state.get('habits', [])

STOPWORDS = {'a','an','the','to','on','of','for','and','or','in','is','it','at','with',
             'was','that','this','be','are','has','had','not','but','from','by','we','i',
             'you','they','he','she','option','do','doing'}

def words(text):
    return {w for w in re.sub(r'[^a-z0-9\s]', ' ', text.lower()).split() if w and w not in STOPWORDS}

def overlaps(a, b):
    wa, wb = words(a), words(b)
    return bool(wa) and bool(wb) and bool(wa & wb)

# ── Per-option habit bias ─────────────────────────────────────────────────
adjusted = []
for opt in options:
    score = float(opt.get('score', opt.get('weight', 0.5)))
    label = (opt.get('label') or opt.get('id') or '').lower()
    oid = opt.get('id', label[:8])

    habit_pull = 1.0
    reason = 'outcompeted'
    for he in habits:
        h_label = (he.get('label') or he.get('pattern') or '').lower()
        if h_label and (overlaps(h_label, label) or overlaps(h_label, oid)):
            h_strength = float(he.get('strength', 0.5))
            habit_pull = 0.9 + 0.2 * h_strength
            reason = f'outcompeted (habit {h_label[:30]} pull={h_strength:.2f})'
            break

    adj = round(score * habit_pull, 4)
    adjusted.append({'id': oid, 'label': opt.get('label',''), 'score': score, 'adjusted': adj, 'habit_pull': round(habit_pull, 4)})

# ── Epsilon-greedy selection ──────────────────────────────────────────────
method = 'weighted'
if random.random() < epsilon and len(adjusted) > 1:
    chosen = random.choice(adjusted)
    method = f'explore (epsilon={epsilon})'
else:
    chosen = max(adjusted, key=lambda x: x['adjusted'])
    method = 'greedy'

losers = [a for a in adjusted if a['id'] != chosen['id']]

# ── Record losers (unless --no-record) ────────────────────────────────────
if not no_record and losers:
    now = os.environ.get('NOW', __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))
    sup_state = copy.deepcopy(habit_state)
    for loser in losers:
        sup_state.setdefault('suppressions', []).append({
            'id': loser['id'],
            'label': loser.get('label', ''),
            'score': loser['score'],
            'reason': loser.get('habit_pull') != 1.0 and f"outcompeted (habit bias)" or "outcompeted",
            'timestamp': now
        })
    # Cap suppressions to 50 entries
    sup_state['suppressions'] = sup_state['suppressions'][-50:]
    tmp = state_file + '.tmp.' + str(os.getpid())
    with open(tmp, 'w') as f:
        json.dump(sup_state, f, indent=2)
    os.rename(tmp, state_file)

print(json.dumps({
    'chosen': chosen,
    'adjusted_scores': adjusted,
    'losers': [{'id': l['id'], 'label': l.get('label',''), 'score': l['score'], 'adjusted': l['adjusted']} for l in losers],
    'method': method,
    'epsilon': epsilon
}, indent=2))
PYTHON
)

echo "$RESULT"
exit 0