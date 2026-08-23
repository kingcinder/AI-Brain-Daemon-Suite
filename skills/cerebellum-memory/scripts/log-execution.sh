#!/bin/bash
# log-execution.sh — Record one rep of executing a skill, refining its
# precision (how close to the target outcome) and smoothness (how
# consistent that has been over time, not just the running average).
# Usage: log-execution.sh --skill "<name>" --quality <0.0-1.0> [--note "..."]
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No cerebellum state found"; exit 1; }

SKILL=""; QUALITY=""; PREDICTED=""; NOTE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --skill) SKILL="$2"; shift 2 ;;
        --quality) QUALITY="$2"; shift 2 ;;
        --predicted) PREDICTED="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$SKILL" ] || [ -z "$QUALITY" ] && { echo "Usage: log-execution.sh --skill \"...\" --quality <0.0-1.0> [--predicted <0.0-1.0>] [--note \"...\"]"; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXISTS=$(jq --arg s "$SKILL" '.skills | has($s)' "$STATE_FILE")

if [ "$EXISTS" != "true" ]; then
    jq --arg s "$SKILL" --argjson q "$QUALITY" --arg now "$NOW" \
      '.skills[$s] = {precision: $q, smoothness: 0.5, reps: 1, lastRefined: $now, recentCorrections: [], recentPredictions: []}' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    # A brand-new skill's very first rep still records a forward-model
    # prediction when one was supplied (the create path above skips the
    # python EMA block, so record the PE here instead of dropping it).
    if [ -n "$PREDICTED" ]; then
        NOW="$NOW" PREDICTED="$PREDICTED" QUALITY="$QUALITY" SKILL="$SKILL" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
skill = state['skills'][os.environ['SKILL']]
predicted = float(os.environ['PREDICTED'])
actual = float(os.environ['QUALITY'])
pe = round(abs(actual - predicted), 3)
skill['predictionError'] = pe
skill['recentPredictions'] = [{'predicted': predicted, 'actual': actual, 'error': pe, 'timestamp': os.environ['NOW']}]
state['skills'][os.environ['SKILL']] = skill
with open(os.environ['STATE_FILE'], 'w') as f:
    json.dump(state, f, indent=2)
"
    fi
else
    # Exponential moving average for precision (alpha 0.3); smoothness rewards
    # being close to the established precision (consistency), not just high quality.
    #
    # Forward-model prediction error (Wolpert, Miall & Kawato): when a
    # predicted outcome was recorded (--predicted), compute PE = |predicted −
    # actual| and let accurate predictions gate FASTER learning (alpha_eff
    # scales 0.6×–1.2× alpha — the teaching signal is strongest when the
    # forward model was right). Without --predicted, behavior is byte-identical
    # to the pre-audit script (alpha_eff = alpha, no prediction recorded).
    NOW="$NOW" QUALITY="$QUALITY" PREDICTED="$PREDICTED" SKILL="$SKILL" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
skill = state['skills'][os.environ['SKILL']]
quality = float(os.environ['QUALITY'])
alpha = 0.3
old_precision = skill.get('precision', 0.5)
predicted_raw = os.environ.get('PREDICTED', '').strip()
pe = None
alpha_eff = alpha
if predicted_raw:
    predicted = float(predicted_raw)
    pe = round(abs(quality - predicted), 3)
    alpha_eff = alpha * max(0.5, min(1.2, 1.2 - pe))
    old_pe = skill.get('predictionError')
    new_pe = pe if old_pe is None else round(old_pe + alpha * (pe - old_pe), 3)
    skill['predictionError'] = new_pe
    skill.setdefault('recentPredictions', []).insert(0, {
        'predicted': predicted, 'actual': quality, 'error': pe,
        'timestamp': os.environ['NOW']})
    skill['recentPredictions'] = skill['recentPredictions'][:10]
new_precision = old_precision + alpha_eff * (quality - old_precision)
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
if [ -n "$PREDICTED" ]; then
    NEW_PE=$(jq -r --arg s "$SKILL" '.skills[$s].predictionError // "n/a"' "$STATE_FILE")
    echo "✅ $SKILL: precision=$NEW_PRECISION smoothness=$NEW_SMOOTH (PE=$NEW_PE)"
else
    echo "✅ $SKILL: precision=$NEW_PRECISION smoothness=$NEW_SMOOTH"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/log-event.sh" execution skill="$SKILL" quality="$QUALITY" 2>/dev/null || true
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
