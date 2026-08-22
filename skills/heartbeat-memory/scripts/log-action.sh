#!/bin/bash
# log-action.sh — Confirm what actually happened after a beat
# Usage: log-action.sh --action <id> [--note "..."] [--skipped]
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
exec 200>"$STATE_FILE.lock"
flock 200

ACTION=""; NOTE=""; SKIPPED=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --action) ACTION="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --skipped) SKIPPED=true; shift ;;
        *) shift ;;
    esac
done

if [ -z "$ACTION" ]; then
    echo "Usage: log-action.sh --action <id> [--note \"...\"] [--skipped]"
    exit 1
fi

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ No heartbeat state found at $STATE_FILE"
    exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENTRY=$(jq -n --arg action "$ACTION" --arg note "$NOTE" --arg ts "$NOW" --argjson skipped "$SKIPPED" \
  '{action: $action, note: $note, timestamp: $ts, skipped: $skipped}')

if [ "$SKIPPED" = true ]; then
    jq --argjson entry "$ENTRY" \
      '.actionHistory = ([$entry] + .actionHistory | .[0:20])' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "📝 Logged (skipped): $ACTION"
else
    jq --argjson entry "$ENTRY" --arg now "$NOW" \
      '.actionHistory = ([$entry] + .actionHistory | .[0:20]) | .options[$entry.action].lastDone = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Logged: $ACTION — $NOTE"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/log-event.sh" action action="$ACTION" skipped="$SKIPPED" 2>/dev/null || true
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
