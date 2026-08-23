#!/bin/bash
# note-salience.sh — Hippocampus consumer for amygdala salience_tag signals.
#
# The amygdala publishes a salience_tag when it tags a high-salience event
# (LeDoux dual-pathway; McGaugh memory enhancement). This consumer records
# that tag as a salience hint so the next encode-pipeline run boosts the
# encoding weight of that domain — the amygdala's output literally biases
# how strongly the hippocampus encodes.
#
# Usage: note-salience.sh --emotion <label> --salience <0-1>
# Dispatched by route-signals.sh from amygdala-memory|salience_tag.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/salience-hints.json"

EMOTION=""
SALIENCE="0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emotion)  EMOTION="$2"; shift 2 ;;
        --salience) SALIENCE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$EMOTION" ]]; then
    echo "note-salience.sh: --emotion is required" >&2
    exit 1
fi

# Clamp salience to [0,1]
if [[ "$SALIENCE" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    SALIENCE=$(awk -v s="$SALIENCE" 'BEGIN { if (s>1) s=1; if (s<0) s=0; print s }')
else
    SALIENCE="0.0"
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "$STATE_FILE")"

# Serialize read-modify-write (concurrent note-salience / gate dispatches).
exec 200>"$STATE_FILE.lock"
flock 200

if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"hints": []}' > "$STATE_FILE"
fi

tmp="$STATE_FILE.tmp.$$"
jq --arg emotion "$EMOTION" --argjson salience "$SALIENCE" --arg now "$NOW" \
  '.hints = ([{emotion: $emotion, salience: $salience, at: $now}] + (.hints // []) | .[0:10]) | .lastUpdated = $now' \
  "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

echo "🧠 Salience hint recorded: $EMOTION (salience $SALIENCE) — next encode pass will weigh this domain stronger."
