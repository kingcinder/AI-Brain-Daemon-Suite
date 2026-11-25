#!/usr/bin/env bash
# log-event.sh — Append structured event to brain-events.jsonl
# Usage: ./scripts/log-event.sh <event_name> [key=value ...]
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
EVENTS_FILE="$WORKSPACE/memory/brain-events.jsonl"
EVENT="${1:-unknown}"; shift || true
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
JSON="{\"ts\":\"$TS\",\"type\":\"insula\",\"event\":\"$EVENT\""
for pair in "$@"; do
  key="${pair%%=*}"; val="${pair#*=}"
  if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then JSON="$JSON,\"$key\":$val"
  else JSON="$JSON,\"$key\":\"$val\""; fi
done
JSON="$JSON}"
mkdir -p "$(dirname "$EVENTS_FILE")"
echo "$JSON" >> "$EVENTS_FILE"
