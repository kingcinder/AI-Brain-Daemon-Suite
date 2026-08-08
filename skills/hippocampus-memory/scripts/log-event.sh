#!/bin/bash
# log-event.sh — Log hippocampus events to brain-events.jsonl
# Part of the hippocampus-memory skill (ClawHub: @ImpKind/hippocampus-memory)
#
# Usage: log-event.sh <event> [key=value ...]
# Events: encoding, decay, consolidation
#
# Examples:
#   log-event.sh encoding memories_created=3 memories_reinforced=7
#   log-event.sh decay memories_decayed=2

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
LOG_FILE="$WORKSPACE/memory/brain-events.jsonl"

mkdir -p "$(dirname "$LOG_FILE")"

EVENT="${1:-unknown}"
shift 1 2>/dev/null || true

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
JSON="{\"ts\":\"$TS\",\"type\":\"hippocampus\",\"event\":\"$EVENT\""

for arg in "$@"; do
    KEY="${arg%%=*}"
    VALUE="${arg#*=}"
    if [[ "$VALUE" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        JSON="$JSON,\"$KEY\":$VALUE"
    else
        VALUE="${VALUE//\"/\\\"}"
        JSON="$JSON,\"$KEY\":\"$VALUE\""
    fi
done

JSON="$JSON}"
echo "$JSON" >> "$LOG_FILE"
