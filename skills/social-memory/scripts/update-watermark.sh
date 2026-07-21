#!/bin/bash
# update-watermark.sh — Advance watermark after processing social signals
# Usage: update-watermark.sh --from-signals
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SIGNALS_FILE="$WORKSPACE/memory/social-signals.jsonl"
WATERMARK_FILE="$WORKSPACE/memory/social-watermark.json"

[ "$1" != "--from-signals" ] && { echo "Usage: update-watermark.sh --from-signals"; exit 1; }
[ ! -s "$SIGNALS_FILE" ] && { echo "ℹ️ No signals to advance watermark from"; exit 0; }

LAST_ID=$(tail -1 "$SIGNALS_FILE" | jq -r '.id // empty' 2>/dev/null || echo "")
[ -z "$LAST_ID" ] && { echo "ℹ️ No valid signal ID found"; exit 0; }

jq -n --arg id "$LAST_ID" '{lastProcessedSignal: $id}' > "$WATERMARK_FILE"
echo "✅ Watermark advanced to $LAST_ID"
