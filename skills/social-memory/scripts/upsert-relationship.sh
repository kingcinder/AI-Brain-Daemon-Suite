#!/bin/bash
# upsert-relationship.sh — Create or update a relationship's basic info
# Usage: upsert-relationship.sh --id <id> --name "..." [--type human|ai_agent] [--platform "..."]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

ID=""; NAME=""; TYPE="human"; PLATFORM="primary_user"

while [[ $# -gt 0 ]]; do
    case $1 in
        --id) ID="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --type) TYPE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$ID" ] || [ -z "$NAME" ] && { echo "Usage: upsert-relationship.sh --id <id> --name \"...\" [--type human|ai_agent] [--platform \"...\"]"; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXISTS=$(jq --arg id "$ID" '.relationships | has($id)' "$STATE_FILE")

if [ "$EXISTS" = "true" ]; then
    jq --arg id "$ID" --arg name "$NAME" --arg type "$TYPE" --arg platform "$PLATFORM" --arg now "$NOW" \
      '.relationships[$id].name = $name | .relationships[$id].type = $type | .relationships[$id].platform = $platform | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Updated relationship: $ID ($NAME)"
else
    jq --arg id "$ID" --arg name "$NAME" --arg type "$TYPE" --arg platform "$PLATFORM" --arg now "$NOW" \
      '.relationships[$id] = {
          name: $name, type: $type, platform: $platform,
          trust: 0.5, affinity: 0.5,
          firstContact: $now, lastContact: $now, interactionCount: 0,
          beliefs: {}, openLoops: [], notes: []
       } | .lastUpdated = $now' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "✅ Created relationship: $ID ($NAME, $TYPE)"
fi
