#!/bin/bash
# decay-load.sh — Executive load eases back toward baseline over time
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"
[ ! -f "$STATE_FILE" ] && { echo "❌ No PFC state found"; exit 1; }

CURRENT=$(jq -r '.executiveLoad' "$STATE_FILE")
BASELINE=0.3
NEW=$(awk -v c="$CURRENT" -v b="$BASELINE" 'BEGIN {printf "%.3f", c + (b - c) * 0.2}')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --argjson v "$NEW" --arg now "$NOW" '.executiveLoad = $v | .lastUpdated = $now' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
echo "🧭 Executive load: $CURRENT → $NEW"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
