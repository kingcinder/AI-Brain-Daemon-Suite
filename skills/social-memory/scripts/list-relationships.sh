#!/bin/bash
# list-relationships.sh — Usage: list-relationships.sh [--type human|ai_agent]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

TYPE_FILTER=""
[ "$1" = "--type" ] && TYPE_FILTER="$2"

FILTER='.relationships | to_entries[]'
[ -n "$TYPE_FILTER" ] && FILTER="$FILTER | select(.value.type == \"$TYPE_FILTER\")"

COUNT=$(jq "[$FILTER] | length" "$STATE_FILE")
[ "$COUNT" -eq 0 ] && { echo "No relationships recorded."; exit 0; }

jq -r "$FILTER | \"\\(.key): \\(.value.name) (\\(.value.type), trust \\(.value.trust), affinity \\(.value.affinity), \\(.value.interactionCount) interactions)\"" "$STATE_FILE"
