#!/bin/bash
# open-loops.sh — Track what's owed or pending with someone
# Usage:
#   open-loops.sh add --id <id> --description "..."
#   open-loops.sh resolve --id <id> --loop-id <loop_id>
#   open-loops.sh list [--id <id>]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

CMD="${1:-}"; shift 1 2>/dev/null || true
ID=""; DESC=""; LOOP_ID=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --id) ID="$2"; shift 2 ;;
        --description) DESC="$2"; shift 2 ;;
        --loop-id) LOOP_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$CMD" in
  add)
    [ -z "$ID" ] || [ -z "$DESC" ] && { echo "Usage: open-loops.sh add --id <id> --description \"...\""; exit 1; }
    EXISTS=$(jq --arg id "$ID" '.relationships | has($id)' "$STATE_FILE")
    [ "$EXISTS" != "true" ] && { echo "❌ No relationship '$ID' found."; exit 1; }
    LOOP_ID="loop_$(date +%s)_$$"
    jq --arg id "$ID" --arg lid "$LOOP_ID" --arg d "$DESC" --arg now "$NOW" \
      '.relationships[$id].openLoops += [{id:$lid, description:$d, status:"open", createdAt:$now}] | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Open loop added for $ID [$LOOP_ID]: $DESC"
    ;;
  resolve)
    [ -z "$ID" ] || [ -z "$LOOP_ID" ] && { echo "Usage: open-loops.sh resolve --id <id> --loop-id <loop_id>"; exit 1; }
    jq --arg id "$ID" --arg lid "$LOOP_ID" --arg now "$NOW" \
      '(.relationships[$id].openLoops[] | select(.id == $lid) | .status) = "resolved" | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Resolved $LOOP_ID for $ID"
    ;;
  list)
    if [ -n "$ID" ]; then
      jq -r --arg id "$ID" '.relationships[$id].openLoops[]? | select(.status=="open") | "\(.id): \(.description)"' "$STATE_FILE"
    else
      jq -r '.relationships | to_entries[] | .key as $id | .value.openLoops[] | select(.status=="open") | "[\($id)] \(.id): \(.description)"' "$STATE_FILE"
    fi
    ;;
  *) echo "Usage: open-loops.sh add|resolve|list [options]"; exit 1 ;;
esac
