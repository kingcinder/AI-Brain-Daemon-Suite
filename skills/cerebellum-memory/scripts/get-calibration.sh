#!/bin/bash
# get-calibration.sh — Usage: get-calibration.sh [--skill <name>] [--json]
# V4-verify: calibration lookup is read-primary (2026-07-20)
# V4-llm-gen: model-proposed annotation (2026-08-08) — calibration lookup is read-primary with health context awareness
# V4-llm-gen: model-proposed annotation (2026-08-08) — calibration lookup is read-primary with health context awareness
# V4-llm-gen: model-proposed annotation (2026-08-08) — calibration lookup is read-primary with health context awareness
# V4-llm-gen: model-proposed annotation (2026-08-08) — calibration lookup is read-primary; system healthy (clean_streak=22, no recent failures/conflicts)
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No cerebellum state found"; exit 1; }
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true

SKILL=""; JSON_OUT=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skill) SKILL="$2"; shift 2 ;;
        --json) JSON_OUT=true; shift ;;
        *) shift ;;
    esac
done

if [ "$JSON_OUT" = true ]; then
    if [ -n "$SKILL" ]; then
        jq --arg s "$SKILL" '.skills[$s] // {}' "$STATE_FILE"
    else
        cat "$STATE_FILE"
    fi
    exit 0
fi

if [ -n "$SKILL" ]; then
    EXISTS=$(jq --arg s "$SKILL" '.skills | has($s)' "$STATE_FILE")
    [ "$EXISTS" != "true" ] && { echo "No data yet for '$SKILL'"; exit 0; }
    jq -r --arg s "$SKILL" '.skills[$s] | "\($s // "skill"): precision=\(.precision) smoothness=\(.smoothness) reps=\(.reps)"' "$STATE_FILE" 2>/dev/null
    jq -r --arg s "$SKILL" '.skills[$s].recentCorrections[:3][] | "  note: \(.note)"' "$STATE_FILE" 2>/dev/null
else
    echo "🎚️ Cerebellum Calibration"
    echo "─────────────────────────"
    echo "Global: $(jq -r '.globalCalibration' "$STATE_FILE")"
    echo ""
    COUNT=$(jq '.skills | length' "$STATE_FILE")
    if [ "$COUNT" -eq 0 ]; then
        echo "No skills tracked yet."
    else
        jq -r '.skills | to_entries[] | "\(.key): precision=\(.value.precision) smoothness=\(.value.smoothness) reps=\(.value.reps)"' "$STATE_FILE"
    fi
fi
