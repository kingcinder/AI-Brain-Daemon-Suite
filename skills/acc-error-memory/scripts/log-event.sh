#!/usr/bin/env bash
# log-event.sh — Append a structured event to brain-events.jsonl
# Usage: ./scripts/log-event.sh <event_name> [key=value ...]
# Example: ./scripts/log-event.sh analysis errors_found=2 patterns_active=3
#
# Event type is always "acc-error" to distinguish from anterior-cingulate-memory
# which writes "acc-conflict" events.

set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}"
EVENTS_FILE="$WORKSPACE/memory/brain-events.jsonl"

EVENT="${1:-unknown}"
shift || true

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build JSON — start with required fields
JSON="{\"ts\":\"$TS\",\"type\":\"acc-error\",\"event\":\"$EVENT\""

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
