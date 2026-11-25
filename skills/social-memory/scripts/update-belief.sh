#!/bin/bash
# update-belief.sh — Theory of mind: record what we think this person/agent
# believes, wants, or feels. Free-form key/value.
# Usage: update-belief.sh --id <id> --key "wants" --value "to ship before Friday"
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

ID=""; KEY=""; VALUE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --id) ID="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --value) VALUE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$ID" ] || [ -z "$KEY" ] && { echo "Usage: update-belief.sh --id <id> --key \"...\" --value \"...\""; exit 1; }

EXISTS=$(jq --arg id "$ID" '.relationships | has($id)' "$STATE_FILE")
[ "$EXISTS" != "true" ] && { echo "❌ No relationship '$ID' found. Run upsert-relationship.sh first."; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg id "$ID" --arg key "$KEY" --arg value "$VALUE" --arg now "$NOW" \
  '.relationships[$id].beliefs[$key] = $value | .lastUpdated = $now' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "✅ Belief recorded for $ID: $KEY = $VALUE"
