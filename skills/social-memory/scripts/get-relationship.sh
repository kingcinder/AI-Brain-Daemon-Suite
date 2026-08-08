#!/bin/bash
# get-relationship.sh — Usage: get-relationship.sh --id <id> [--json]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true

ID=""; JSON_OUT=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --id) ID="$2"; shift 2 ;;
        --json) JSON_OUT=true; shift ;;
        *) shift ;;
    esac
done
[ -z "$ID" ] && { echo "Usage: get-relationship.sh --id <id>"; exit 1; }

EXISTS=$(jq --arg id "$ID" '.relationships | has($id)' "$STATE_FILE")
[ "$EXISTS" != "true" ] && { echo "❌ No relationship '$ID' found."; exit 1; }

if [ "$JSON_OUT" = true ]; then
    jq --arg id "$ID" '.relationships[$id]' "$STATE_FILE"
    exit 0
fi

jq -r --arg id "$ID" '.relationships[$id] |
  "\(.name) (\(.type), \(.platform))\n" +
  "Trust: \(.trust)  Affinity: \(.affinity)  Interactions: \(.interactionCount)\n" +
  "First contact: \(.firstContact)  Last contact: \(.lastContact)\n" +
  "\nBeliefs:\n" + ((.beliefs | to_entries | map("  - \(.key): \(.value)") | join("\n")) // "  (none recorded)") +
  "\n\nOpen loops:\n" + ((.openLoops | map(select(.status=="open")) | map("  - \(.description)") | join("\n")) // "  (none)") +
  "\n\nRecent notes:\n" + ((.notes[:5] | map("  - [\(.timestamp)] \(.text)") | join("\n")) // "  (none)")
' "$STATE_FILE"
