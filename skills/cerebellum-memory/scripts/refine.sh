#!/bin/bash
# refine.sh — Recompute global calibration from tracked skills (periodic, cron)
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No cerebellum state found"; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
COUNT=$(jq '.skills | length' "$STATE_FILE")

if [ "$COUNT" -eq 0 ]; then
    echo "🎚️ No skills tracked yet — nothing to refine."
    exit 0
fi

NEW_GLOBAL=$(jq '[.skills[].precision] | add / length' "$STATE_FILE")
jq --argjson g "$NEW_GLOBAL" --arg now "$NOW" '.globalCalibration = $g | .lastUpdated = $now' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "🎚️ Global calibration recomputed: $NEW_GLOBAL (across $COUNT tracked skills)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
