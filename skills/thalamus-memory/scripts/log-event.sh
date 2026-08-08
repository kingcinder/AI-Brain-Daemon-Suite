#!/bin/bash
# log-event.sh — Emit a thalamus event to brain-events.jsonl
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
EVENT_LOG="$WORKSPACE/memory/brain-events.jsonl"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT="${1:-tick}"
shift || true

# Build a flat JSON object from remaining args
PAIRS=""
for arg in "$@"; do
    if [[ "$arg" =~ ^([^=]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        PAIRS="$PAIRS, \"$key\": \"$val\""
    fi
done

mkdir -p "$(dirname "$EVENT_LOG")"
echo "{\"ts\":\"$NOW\",\"type\":\"thalamus\",\"event\":\"$EVENT\"$PAIRS}" >> "$EVENT_LOG"

exit 0
