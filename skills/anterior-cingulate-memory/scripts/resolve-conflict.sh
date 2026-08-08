#!/usr/bin/env bash
# scripts/resolve-conflict.sh — Mark a conflict resolved and lower conflict load
#
# Usage:
#   ./resolve-conflict.sh --id <conflict_id> --resolution "..."
#   ./resolve-conflict.sh --all   (resolve all active conflicts)
#
# Lists active conflicts if run with no arguments.

set -e

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"

CONFLICT_ID=""
RESOLUTION=""
RESOLVE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)         CONFLICT_ID="$2";  shift 2 ;;
    --resolution) RESOLUTION="$2";   shift 2 ;;
    --all)        RESOLVE_ALL=true;  shift ;;
    --help|-h)
      sed -n '2,10p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: conflict-state.json not found. Run ./install.sh first." >&2; exit 1
fi

# ── No args: list active conflicts ────────────────────────────────────────────
if [[ -z "$CONFLICT_ID" && "$RESOLVE_ALL" == false ]]; then
  COUNT=$(jq '.activeConflicts | length' "$STATE_FILE")
  if [[ "$COUNT" -eq 0 ]]; then
    echo "⚡ No active conflicts."
  else
    echo "⚡ Active conflicts ($COUNT):"
    jq -r '.activeConflicts | to_entries[] | "   \(.key)  [\(.value.type)/\(.value.severity)]  \(.value.description)"' "$STATE_FILE"
  fi
  exit 0
fi

# Serialize read-modify-write against the other conflict-state.json writers
# (log-conflict, flag-attention, decay-load, encode-pipeline).
exec 200>"$STATE_FILE.lock"
flock 200

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

resolve_one() {
  local ID="$1"
  local RESOLUTION_TEXT="$2"

  # Check conflict exists
  EXISTS=$(jq --arg id "$ID" '.activeConflicts[$id] // empty' "$STATE_FILE")
  if [[ -z "$EXISTS" ]]; then
    echo "ERROR: Conflict '$ID' not found in active conflicts." >&2
    return 1
  fi

  INTENSITY=$(jq --arg id "$ID" '.activeConflicts[$id].intensity' "$STATE_FILE")
  TYPE=$(jq -r --arg id "$ID" '.activeConflicts[$id].type' "$STATE_FILE")

  CURRENT_LOAD=$(jq -r '.conflictLoad' "$STATE_FILE")
  BASELINE=$(jq -r '.baseline.conflictLoad' "$STATE_FILE")
  REDUCTION=$(echo "$INTENSITY * 0.10" | bc -l)
  NEW_LOAD=$(echo "if ($CURRENT_LOAD - $REDUCTION < $BASELINE) $BASELINE else ($CURRENT_LOAD - $REDUCTION)" | bc -l)
  NEW_LOAD=$(printf "%.4f" "$NEW_LOAD")

  UPDATED=$(jq \
    --arg id "$ID" \
    --arg resolution "$RESOLUTION_TEXT" \
    --arg now "$NOW" \
    --argjson newLoad "$NEW_LOAD" \
    '
    .conflictLoad = $newLoad |
    .lastUpdated = $now |
    .resolvedConflicts += [(.activeConflicts[$id] + {
      id: $id,
      resolution: $resolution,
      resolvedAt: $now
    })] |
    del(.activeConflicts[$id]) |
    .stats.totalResolved += 1
    ' "$STATE_FILE")

  echo "$UPDATED" > "$STATE_FILE.tmp.$$"
  mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

  local DELTA
  DELTA=$(echo "$NEW_LOAD - $CURRENT_LOAD" | bc -l)
  local DELTA_FMT
  DELTA_FMT=$(printf "%.4f" "$DELTA")

  echo "⚡ Conflict resolved!"
  echo "   ID:    $ID"
  echo "   Type:  $TYPE"
  echo "   Load:  $CURRENT_LOAD → $NEW_LOAD ($DELTA_FMT)"
  [[ -n "$RESOLUTION_TEXT" ]] && echo "   How:   $RESOLUTION_TEXT"

  "$SKILL_DIR/scripts/log-event.sh" \
    resolve \
    "id=$ID" \
    "type=$TYPE" \
    "load_before=$CURRENT_LOAD" \
    "load_after=$NEW_LOAD" 2>/dev/null || true
}

if [[ "$RESOLVE_ALL" == true ]]; then
  CONFLICT_IDS=$(jq -r '.activeConflicts | keys[]' "$STATE_FILE")
  if [[ -z "$CONFLICT_IDS" ]]; then
    echo "⚡ No active conflicts to resolve."
    exit 0
  fi
  RESOLUTION="${RESOLUTION:-manual bulk resolution}"
  for ID in $CONFLICT_IDS; do
    resolve_one "$ID" "$RESOLUTION"
  done
else
  resolve_one "$CONFLICT_ID" "$RESOLUTION"
fi

"$SKILL_DIR/scripts/sync-state.sh" --quiet
