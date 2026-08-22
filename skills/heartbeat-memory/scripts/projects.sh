#!/bin/bash
# projects.sh — Manage the project registry heartbeat draws candidates from
#
# Usage:
#   projects.sh add --title "..." --type unfinished|own [--note "..."]
#   projects.sh list [--type unfinished|own] [--status active|paused|done]
#   projects.sh touch --id <id>              # mark as recently worked on
#   projects.sh complete --id <id>
#   projects.sh pause --id <id>

set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
exec 200>"$STATE_FILE.lock"
flock 200

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ No heartbeat state found at $STATE_FILE"
    exit 1
fi

CMD="${1:-}"
shift 1 2>/dev/null || true

TITLE=""; TYPE="unfinished"; NOTE=""; ID=""; STATUS_FILTER=""; TYPE_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --title) TITLE="$2"; shift 2 ;;
        --type) TYPE="$2"; TYPE_FILTER="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --id) ID="$2"; shift 2 ;;
        --status) STATUS_FILTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$CMD" in
  add)
    if [ -z "$TITLE" ]; then echo "Usage: projects.sh add --title \"...\" --type unfinished|own [--note \"...\"]"; exit 1; fi
    ID="proj_$(date +%s)_$$"
    jq --arg id "$ID" --arg title "$TITLE" --arg type "$TYPE" --arg note "$NOTE" --arg now "$NOW" \
      '.projects += [{id: $id, title: $title, type: $type, status: "active", note: $note, createdAt: $now, lastTouchedAt: $now}] | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Added project [$ID]: $TITLE ($TYPE)"
    ;;

  list)
    FILTER='.projects[]'
    [ -n "$TYPE_FILTER" ] && FILTER="$FILTER | select(.type == \"$TYPE_FILTER\")"
    [ -n "$STATUS_FILTER" ] && FILTER="$FILTER | select(.status == \"$STATUS_FILTER\")"
    COUNT=$(jq "[$FILTER] | length" "$STATE_FILE")
    if [ "$COUNT" -eq 0 ]; then
        echo "No projects match."
        exit 0
    fi
    jq -r "$FILTER | \"[\\(.status)] \\(.id): \\(.title) (\\(.type))\" + (if .note != \"\" then \"\\n   note: \\(.note)\" else \"\" end)" "$STATE_FILE"
    ;;

  touch)
    [ -z "$ID" ] && { echo "Usage: projects.sh touch --id <id>"; exit 1; }
    jq --arg id "$ID" --arg now "$NOW" \
      '(.projects[] | select(.id == $id) | .lastTouchedAt) = $now | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Touched $ID"
    ;;

  complete)
    [ -z "$ID" ] && { echo "Usage: projects.sh complete --id <id>"; exit 1; }
    jq --arg id "$ID" --arg now "$NOW" \
      '(.projects[] | select(.id == $id) | .status) = "done" | (.projects[] | select(.id == $id) | .lastTouchedAt) = $now | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Marked $ID complete"
    ;;

  pause)
    [ -z "$ID" ] && { echo "Usage: projects.sh pause --id <id>"; exit 1; }
    jq --arg id "$ID" --arg now "$NOW" \
      '(.projects[] | select(.id == $id) | .status) = "paused" | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Paused $ID"
    ;;

  *)
    echo "Usage: projects.sh add|list|touch|complete|pause [options]"
    exit 1
    ;;
esac
