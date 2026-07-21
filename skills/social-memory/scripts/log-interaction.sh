#!/bin/bash
# log-interaction.sh — Record an interaction with a relationship
# Usage: log-interaction.sh --id <id> --summary "..." [--trust-delta +/-0.x] [--affinity-delta +/-0.x]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

ID=""; SUMMARY=""; TRUST_DELTA="0"; AFFINITY_DELTA="0"

while [[ $# -gt 0 ]]; do
    case $1 in
        --id) ID="$2"; shift 2 ;;
        --summary) SUMMARY="$2"; shift 2 ;;
        --trust-delta) TRUST_DELTA="$2"; shift 2 ;;
        --affinity-delta) AFFINITY_DELTA="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$ID" ] && { echo "Usage: log-interaction.sh --id <id> --summary \"...\" [--trust-delta x] [--affinity-delta x]"; exit 1; }

EXISTS=$(jq --arg id "$ID" '.relationships | has($id)' "$STATE_FILE")
if [ "$EXISTS" != "true" ]; then
    echo "❌ No relationship '$ID' found. Run upsert-relationship.sh first."
    exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOTE=$(jq -n --arg text "$SUMMARY" --arg ts "$NOW" '{text: $text, timestamp: $ts}')

jq --arg id "$ID" --argjson note "$NOTE" --argjson td "$TRUST_DELTA" --argjson ad "$AFFINITY_DELTA" --arg now "$NOW" '
  .relationships[$id].notes = ([$note] + .relationships[$id].notes | .[0:20]) |
  .relationships[$id].interactionCount += 1 |
  .relationships[$id].lastContact = $now |
  (.relationships[$id].trust + $td) as $nt |
  .relationships[$id].trust = (if $nt < 0 then 0 elif $nt > 1 then 1 else $nt end) |
  (.relationships[$id].affinity + $ad) as $na |
  .relationships[$id].affinity = (if $na < 0 then 0 elif $na > 1 then 1 else $na end) |
  .lastUpdated = $now
' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "✅ Logged interaction with $ID: $SUMMARY"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/log-event.sh" interaction id="$ID" trustDelta="$TRUST_DELTA" affinityDelta="$AFFINITY_DELTA" 2>/dev/null || true
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
