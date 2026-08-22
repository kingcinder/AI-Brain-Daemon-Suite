#!/bin/bash
# get-neuromod.sh — Shared reader for the global neuromodulator vector.
#
# Usage:
#   get-neuromod.sh --json              # full vector (modulators + composites)
#   get-neuromod.sh --get <modulator>   # single 0-1 value (e.g. dopamine)
#   get-neuromod.sh --composite <name>  # composite value (arousal/valence/stressIndex)
#
# Neutral-by-default: an absent file or field returns the baseline (0.5;
# sleepPressure 0), never an error — readers can call this unconditionally.
#
# Read-only: takes the shared lock only to avoid reading mid-replace.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/neuromod-state.json"

exec 200>"$STATE_FILE.lock"
flock 200

BASELINE="0.5"
if [[ "$1" = "--get" ]]; then
    MOD="$2"
    [[ "$MOD" = "sleepPressure" ]] && BASELINE="0"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg m "$MOD" '.modulators[$m].value // '"$BASELINE" \
          "$STATE_FILE" 2>/dev/null || echo "$BASELINE"
    else
        echo "$BASELINE"
    fi
    exit 0
elif [[ "$1" = "--composite" ]]; then
    NAME="$2"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg n "$NAME" '.composites[$n] // 0.5' "$STATE_FILE" 2>/dev/null || echo "0.5"
    else
        echo "0.5"
    fi
    exit 0
elif [[ "$1" = "--json" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        printf '%s' '{"version":1,"modulators":{},"composites":{"arousal":0.5,"valence":0.5,"stressIndex":0.5},"missingSources":[]}'
    fi
    exit 0
fi

echo "Usage: get-neuromod.sh --json | --get <modulator> | --composite <name>" >&2
exit 1