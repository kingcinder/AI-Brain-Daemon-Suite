#!/usr/bin/env bash
# scripts/decay-load.sh — Conflict load drifts toward baseline over time.
# Designed to run on cron every 4 hours.
# No new conflicts → load moves 20% closer to baseline per run.

set -e

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"

if [[ ! -f "$STATE_FILE" ]]; then exit 0; fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

CURRENT=$(jq -r '.conflictLoad' "$STATE_FILE")
BASELINE=$(jq -r '.baseline.conflictLoad' "$STATE_FILE")

# Skip if already at or below baseline
if awk "BEGIN{exit !($CURRENT <= $BASELINE)}"; then
  exit 0
fi

# Decay: move 20% of the gap toward baseline
GAP=$(echo "$CURRENT - $BASELINE" | bc -l)
DECAY=$(echo "$GAP * 0.20" | bc -l)
NEW_LOAD=$(echo "$CURRENT - $DECAY" | bc -l)

# Clamp to baseline floor
if awk "BEGIN{exit !($NEW_LOAD < $BASELINE)}"; then
  NEW_LOAD="$BASELINE"
fi

NEW_LOAD=$(printf "%.4f" "$NEW_LOAD")

UPDATED=$(jq \
  --argjson newLoad "$NEW_LOAD" \
  --arg now "$NOW" \
  '.conflictLoad = $newLoad | .lastUpdated = $now' \
  "$STATE_FILE")
echo "$UPDATED" > "$STATE_FILE"

"$SKILL_DIR/scripts/sync-state.sh" --quiet

"$SKILL_DIR/scripts/log-event.sh" \
  decay \
  "load_before=$CURRENT" \
  "load_after=$NEW_LOAD" \
  "baseline=$BASELINE" 2>/dev/null || true

echo "⚡ Conflict load decayed: $CURRENT → $NEW_LOAD (baseline: $BASELINE)"
