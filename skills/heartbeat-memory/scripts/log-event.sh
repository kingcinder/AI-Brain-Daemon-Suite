#!/bin/bash
# log-event.sh — Log heartbeat events to brain-events.jsonl
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
LOG_FILE="$WORKSPACE/memory/brain-events.jsonl"
mkdir -p "$(dirname "$LOG_FILE")"
EVENT="${1:-unknown}"
shift 1 2>/dev/null || true
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
JSON="{\"ts\":\"$TS\",\"type\":\"heartbeat\",\"event\":\"$EVENT\""
for arg in "$@"; do
    KEY="${arg%%=*}"; VALUE="${arg#*=}"
    if [[ "$VALUE" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        JSON="$JSON,\"$KEY\":$VALUE"
    else
        VALUE="${VALUE//\"/\\\"}"
        JSON="$JSON,\"$KEY\":\"$VALUE\""
    fi
done
JSON="$JSON}"
echo "$JSON" >> "$LOG_FILE"
