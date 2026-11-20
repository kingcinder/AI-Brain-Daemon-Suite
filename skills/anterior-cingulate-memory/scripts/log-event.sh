#!/usr/bin/env bash
# log-event.sh — Append a structured event to brain-events.jsonl
# Usage: ./scripts/log-event.sh <event_name> [key=value ...]
# Example: ./scripts/log-event.sh encoding conflicts_found=2 load=0.45
#
# Event type is always "acc-conflict" to distinguish from acc-error-memory
# which writes "acc-error" events.

set -euo pipefail

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
EVENTS_FILE="$WORKSPACE/memory/brain-events.jsonl"

EVENT="${1:-unknown}"
shift || true

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build JSON — start with required fields
JSON="{\"ts\":\"$TS\",\"type\":\"acc-conflict\",\"event\":\"$EVENT\""

# Append any key=value pairs passed as extra args
for pair in "$@"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  # Determine if value is numeric or string
  if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    JSON="$JSON,\"$key\":$val"
  else
    JSON="$JSON,\"$key\":\"$val\""
  fi
done

JSON="$JSON}"

# Ensure events file directory exists
mkdir -p "$(dirname "$EVENTS_FILE")"

echo "$JSON" >> "$EVENTS_FILE"
