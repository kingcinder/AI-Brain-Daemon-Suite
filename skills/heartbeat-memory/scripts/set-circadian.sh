#!/bin/bash
# set-circadian.sh — Configure wake/sleep hours (24h, local-to-UTC-already)
# Usage: set-circadian.sh --wake 7 --sleep 23
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
exec 200>"$STATE_FILE.lock"
flock 200

WAKE=""; SLEEP=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --wake) WAKE="$2"; shift 2 ;;
        --sleep) SLEEP="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$WAKE" ] && [ -z "$SLEEP" ] && { echo "Usage: set-circadian.sh --wake <hour> --sleep <hour>"; exit 1; }
[ ! -f "$STATE_FILE" ] && { echo "❌ No heartbeat state found"; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
[ -n "$WAKE" ] && jq --argjson w "$WAKE" --arg now "$NOW" '.circadian.wakeHour = $w | .lastUpdated = $now' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
[ -n "$SLEEP" ] && jq --argjson s "$SLEEP" --arg now "$NOW" '.circadian.sleepHour = $s | .lastUpdated = $now' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "✅ Circadian updated: wake=$(jq -r '.circadian.wakeHour' "$STATE_FILE") sleep=$(jq -r '.circadian.sleepHour' "$STATE_FILE") (UTC)"
