#!/bin/bash
# inhibitions.sh — Manage impulse-control patterns (things to resist)
# Usage:
#   inhibitions.sh add --pattern "..." --reason "..." [--strength 0.0-1.0]
#   inhibitions.sh list
#   inhibitions.sh remove --id <id>
#   inhibitions.sh check --text "..."   # does this text match an active inhibition?
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"
[ ! -f "$STATE_FILE" ] && { echo "❌ No PFC state found"; exit 1; }

CMD="${1:-}"; shift 1 2>/dev/null || true
PATTERN=""; REASON=""; STRENGTH="0.8"; ID=""; TEXT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --pattern) PATTERN="$2"; shift 2 ;;
        --reason) REASON="$2"; shift 2 ;;
        --strength) STRENGTH="$2"; shift 2 ;;
        --id) ID="$2"; shift 2 ;;
        --text) TEXT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$CMD" in
  add)
    [ -z "$PATTERN" ] && { echo "Usage: inhibitions.sh add --pattern \"...\" --reason \"...\""; exit 1; }
    ID="inh_$(date +%s)_$$"
    jq --arg id "$ID" --arg p "$PATTERN" --arg r "$REASON" --argjson s "$STRENGTH" --arg now "$NOW" \
      '.inhibitions += [{id:$id, pattern:$p, reason:$r, strength:$s, createdAt:$now}] | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Added inhibition [$ID]: $PATTERN ($REASON)"
    ;;
  list)
    COUNT=$(jq '.inhibitions | length' "$STATE_FILE")
    [ "$COUNT" -eq 0 ] && { echo "No inhibitions active."; exit 0; }
    jq -r '.inhibitions[] | "\(.id): \(.pattern) — \(.reason) (strength \(.strength))"' "$STATE_FILE"
    ;;
  remove)
    [ -z "$ID" ] && { echo "Usage: inhibitions.sh remove --id <id>"; exit 1; }
    jq --arg id "$ID" --arg now "$NOW" '.inhibitions = [.inhibitions[] | select(.id != $id)] | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Removed $ID"
    ;;
  check)
    [ -z "$TEXT" ] && { echo "Usage: inhibitions.sh check --text \"...\""; exit 1; }
    jq -r --arg t "$TEXT" '[.inhibitions[] | select(($t | ascii_downcase) | contains(.pattern | ascii_downcase))] | if length > 0 then .[0] else null end' "$STATE_FILE"
    ;;
  *) echo "Usage: inhibitions.sh add|list|remove|check [options]"; exit 1 ;;
esac
