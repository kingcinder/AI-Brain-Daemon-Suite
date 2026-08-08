#!/usr/bin/env bash
# update-watermark.sh — Advance lastProcessedSignal watermark
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
NEW_WATERMARK="${1:?Usage: $0 <signal_id_or_timestamp>}"
[ ! -f "$STATE_FILE" ] && echo "No state file found" && exit 1
UPDATED=$(jq --arg w "$NEW_WATERMARK" '.lastProcessedSignal = $w | .lastUpdated = now | .lastUpdated |= todate' "$STATE_FILE")
echo "$UPDATED" > "$STATE_FILE"
echo "✅ Watermark → $NEW_WATERMARK"
