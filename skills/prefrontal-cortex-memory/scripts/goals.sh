#!/bin/bash
# goals.sh — Manage executive goals
# Usage:
#   goals.sh add --description "..." [--priority 0.0-1.0] [--deadline "..."]
#   goals.sh list [--status active|complete]
#   goals.sh complete --id <id>
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"
[ ! -f "$STATE_FILE" ] && { echo "❌ No PFC state found"; exit 1; }

CMD="${1:-}"; shift 1 2>/dev/null || true
DESC=""; PRIORITY="0.5"; DEADLINE=""; ID=""; STATUS_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --description) DESC="$2"; shift 2 ;;
        --priority) PRIORITY="$2"; shift 2 ;;
        --deadline) DEADLINE="$2"; shift 2 ;;
        --id) ID="$2"; shift 2 ;;
        --status) STATUS_FILTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$CMD" in
  add)
    [ -z "$DESC" ] && { echo "Usage: goals.sh add --description \"...\" [--priority 0.0-1.0]"; exit 1; }
    ID="goal_$(date +%s)_$$"
    jq --arg id "$ID" --arg d "$DESC" --argjson p "$PRIORITY" --arg dl "$DEADLINE" --arg now "$NOW" \
      '.goals += [{id:$id, description:$d, priority:$p, status:"active", deadline:$dl, createdAt:$now}] | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Added goal [$ID]: $DESC (priority $PRIORITY)"
    ;;
  list)
    FILTER='.goals[]'
    [ -n "$STATUS_FILTER" ] && FILTER="$FILTER | select(.status == \"$STATUS_FILTER\")"
    COUNT=$(jq "[$FILTER] | length" "$STATE_FILE")
    [ "$COUNT" -eq 0 ] && { echo "No goals match."; exit 0; }
    jq -r "$FILTER | \"[\\(.status)] \\(.id): \\(.description) (priority \\(.priority))\"" "$STATE_FILE"
    ;;
  complete)
    [ -z "$ID" ] && { echo "Usage: goals.sh complete --id <id>"; exit 1; }
    jq --arg id "$ID" --arg now "$NOW" '(.goals[] | select(.id == $id) | .status) = "complete" | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Completed $ID"
    ;;
  *) echo "Usage: goals.sh add|list|complete [options]"; exit 1 ;;
esac
