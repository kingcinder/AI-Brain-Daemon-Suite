#!/bin/bash
# beat.sh — The heartbeat tick. Decides what the agent should consider doing
# right now, given circadian phase, option cooldowns, and (if installed)
# the prefrontal cortex's executive arbitration over current brain state.
#
# This script DECIDES; it does not execute. It prints a directive for the
# calling agent-turn to act on, and records the decision so log-action.sh
# can later confirm what actually happened.
#
# Usage: beat.sh [--dry-run]

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
PFC_DECIDE="$WORKSPACE/skills/prefrontal-cortex-memory/scripts/decide.sh"
DRY_RUN=false
[ "$1" = "--dry-run" ] && DRY_RUN=true

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ No heartbeat state found at $STATE_FILE"
    exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOUR=$(date -u +"%H" | sed 's/^0//')
[ -z "$HOUR" ] && HOUR=0

WAKE_HOUR=$(jq -r '.circadian.wakeHour // 7' "$STATE_FILE")
SLEEP_HOUR=$(jq -r '.circadian.sleepHour // 23' "$STATE_FILE")

# ── Circadian phase ──────────────────────────────────────────────────────────
PHASE=$(HOUR="$HOUR" WAKE_HOUR="$WAKE_HOUR" SLEEP_HOUR="$SLEEP_HOUR" python3 -c "
import os
hour, wake, sleep = int(os.environ['HOUR']), int(os.environ['WAKE_HOUR']), int(os.environ['SLEEP_HOUR'])
def in_range(h, start, end):
    if start <= end:
        return start <= h < end
    return h >= start or h < end  # wraps past midnight

if in_range(hour, wake, (wake + 2) % 24):
    print('waking')
elif in_range(hour, sleep, (sleep + 1) % 24) or in_range(hour, (sleep + 1) % 24, wake):
    print('asleep')
elif in_range(hour, (sleep - 2) % 24, sleep):
    print('winding_down')
else:
    print('active')
")

echo "💓 Heartbeat — $(date -u +"%H:%M UTC") (phase: $PHASE)"

# ── Build candidate option list ──────────────────────────────────────────────
# `[]?` guards a missing .projects (freshly-initialized state file): jq would
# otherwise error on the null iteration and kill the heartbeat under set -e.
HAS_UNFINISHED=$(jq '[.projects[]? | select(.type == "unfinished" and .status == "active")] | length > 0' "$STATE_FILE")
HAS_OWN=$(jq '[.projects[]? | select(.type == "own" and .status == "active")] | length > 0' "$STATE_FILE")

CANDIDATES=$(HAS_OWN="$HAS_OWN" HAS_UNFINISHED="$HAS_UNFINISHED" NOW="$NOW" PHASE="$PHASE" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
opts = state.get('options', {})
now_str = os.environ['NOW']
from datetime import datetime, timezone

def minutes_since(ts):
    if not ts:
        return float('inf')
    try:
        then = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        now = datetime.fromisoformat(now_str.replace('Z', '+00:00'))
        return (now - then).total_seconds() / 60
    except Exception:
        return float('inf')

phase = os.environ['PHASE']
has_unfinished = os.environ['HAS_UNFINISHED'] == 'true'
has_own = os.environ['HAS_OWN'] == 'true'

candidates = []
for opt_id, cfg in opts.items():
    if opt_id == 'project_work' and not has_unfinished:
        continue
    if opt_id == 'own_projects' and not has_own:
        continue
    if phase == 'asleep' and opt_id != 'dreaming':
        continue  # quiet hours: only dreaming/consolidation is on the table
    cooldown = cfg.get('cooldownMinutes', 0)
    if minutes_since(cfg.get('lastDone')) < cooldown:
        continue
    weight = cfg.get('weight', 0.5)
    # light circadian nudges
    if phase == 'winding_down' and opt_id in ('dreaming', 'social_media'):
        weight *= 1.3
    if phase == 'active' and opt_id in ('project_work', 'own_projects'):
        weight *= 1.2
    if phase == 'waking' and opt_id == 'idle':
        weight *= 1.5
    candidates.append({'id': opt_id, 'label': cfg.get('label', opt_id), 'weight': round(weight, 3)})

print(json.dumps(candidates))
")

CANDIDATE_COUNT=$(echo "$CANDIDATES" | jq 'length')
if [ "$CANDIDATE_COUNT" -eq 0 ]; then
    echo "Nothing eligible right now (cooldowns / quiet hours). Skipping this beat."
    [ "$DRY_RUN" = false ] && jq --arg now "$NOW" '.lastBeat = $now | .beatCount += 1' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    exit 0
fi

echo "Candidates: $(echo "$CANDIDATES" | jq -r '[.[].id] | join(", ")')"

# ── Delegate to prefrontal cortex if installed, else weighted-random ─────────
CHOSEN_ID=""; REASONING=""

if [ -x "$PFC_DECIDE" ]; then
    PFC_RESULT=$("$PFC_DECIDE" --context heartbeat --options "$CANDIDATES" 2>/dev/null || echo "")
    CHOSEN_ID=$(echo "$PFC_RESULT" | jq -r '.chosen // empty' 2>/dev/null || echo "")
    REASONING=$(echo "$PFC_RESULT" | jq -r '.reasoning // empty' 2>/dev/null || echo "")
fi

if [ -z "$CHOSEN_ID" ]; then
    # Fallback: weighted-random pick (no executive arbitration installed/available)
    CHOSEN_ID=$(echo "$CANDIDATES" | python3 -c "
import json, random, sys
candidates = json.load(sys.stdin)
weights = [c['weight'] for c in candidates]
chosen = random.choices(candidates, weights=weights, k=1)[0]
print(chosen['id'])
")
    REASONING="No prefrontal-cortex-memory installed — picked by weighted chance among eligible options."
fi

CHOSEN_LABEL=$(echo "$CANDIDATES" | jq -r --arg id "$CHOSEN_ID" '.[] | select(.id == $id) | .label')

echo ""
echo "👉 Chosen: $CHOSEN_ID — $CHOSEN_LABEL"
echo "   Why: $REASONING"
echo ""
echo "Next: act on this if it makes sense, then run:"
echo "  $SCRIPT_DIR/log-action.sh --action $CHOSEN_ID --note \"what you actually did\""

if [ "$DRY_RUN" = false ]; then
    jq --arg now "$NOW" --arg action "$CHOSEN_ID" \
      '.lastBeat = $now | .beatCount += 1 | .lastChosenAction = $action | .lastChosenAt = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    "$SCRIPT_DIR/log-event.sh" beat phase="$PHASE" chosen="$CHOSEN_ID" 2>/dev/null || true
fi
