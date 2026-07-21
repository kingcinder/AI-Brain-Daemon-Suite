#!/bin/bash
# log-execution.sh — Record one rep of executing a skill, refining its
# precision (how close to the target outcome) and smoothness (how
# consistent that has been over time, not just the running average).
# Usage: log-execution.sh --skill "<name>" --quality <0.0-1.0> [--note "..."]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No cerebellum state found"; exit 1; }

SKILL=""; QUALITY=""; NOTE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --skill) SKILL="$2"; shift 2 ;;
        --quality) QUALITY="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$SKILL" ] || [ -z "$QUALITY" ] && { echo "Usage: log-execution.sh --skill \"...\" --quality <0.0-1.0> [--note \"...\"]"; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXISTS=$(jq --arg s "$SKILL" '.skills | has($s)' "$STATE_FILE")

if [ "$EXISTS" != "true" ]; then
    jq --arg s "$SKILL" --argjson q "$QUALITY" --arg now "$NOW" \
      '.skills[$s] = {precision: $q, smoothness: 0.5, reps: 1, lastRefined: $now, recentCorrections: []}' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
else
    # Exponential moving average for precision (alpha 0.3); smoothness rewards
    # being close to the established precision (consistency), not just high quality.
    NOW="$NOW" QUALITY="$QUALITY" SKILL="$SKILL" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
skill = state['skills'][os.environ['SKILL']]
quality = float(os.environ['QUALITY'])
alpha = 0.3
old_precision = skill.get('precision', 0.5)
new_precision = old_precision + alpha * (quality - old_precision)
consistency = 1 - abs(quality - old_precision)
old_smooth = skill.get('smoothness', 0.5)
new_smooth = old_smooth + alpha * (consistency - old_smooth)
skill['precision'] = round(new_precision, 3)
skill['smoothness'] = round(max(0, min(1, new_smooth)), 3)
skill['reps'] = skill.get('reps', 0) + 1
skill['lastRefined'] = os.environ['NOW']
state['skills'][os.environ['SKILL']] = skill
state['lastUpdated'] = os.environ['NOW']
with open(os.environ['STATE_FILE'], 'w') as f:
    json.dump(state, f, indent=2)
"
fi

if [ -n "$NOTE" ]; then
    jq --arg s "$SKILL" --arg note "$NOTE" --arg now "$NOW" \
      '.skills[$s].recentCorrections = ([{note: $note, timestamp: $now}] + .skills[$s].recentCorrections | .[0:10])' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

NEW_PRECISION=$(jq -r --arg s "$SKILL" '.skills[$s].precision' "$STATE_FILE")
NEW_SMOOTH=$(jq -r --arg s "$SKILL" '.skills[$s].smoothness' "$STATE_FILE")
echo "✅ $SKILL: precision=$NEW_PRECISION smoothness=$NEW_SMOOTH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/log-event.sh" execution skill="$SKILL" quality="$QUALITY" 2>/dev/null || true
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
