#!/bin/bash
# get-state.sh — Human-readable heartbeat overview
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No heartbeat state found"; exit 1; }
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true

[ "$1" = "--json" ] && { cat "$STATE_FILE"; exit 0; }

BEAT_COUNT=$(jq -r '.beatCount' "$STATE_FILE")
LAST_BEAT=$(jq -r '.lastBeat // "never"' "$STATE_FILE")
LAST_ACTION=$(jq -r '.lastChosenAction // "none"' "$STATE_FILE")
WAKE=$(jq -r '.circadian.wakeHour' "$STATE_FILE")
SLEEP=$(jq -r '.circadian.sleepHour' "$STATE_FILE")
ACTIVE_PROJECTS=$(jq '[.projects[] | select(.status == "active")] | length' "$STATE_FILE")

echo "💓 Heartbeat State"
echo "─────────────────────"
echo "Beats so far:    $BEAT_COUNT"
echo "Last beat:       $LAST_BEAT"
echo "Last action:     $LAST_ACTION"
echo "Circadian:       wake ${WAKE}:00 / sleep ${SLEEP}:00 (UTC)"
echo "Active projects: $ACTIVE_PROJECTS"
echo ""
echo "Recent actions:"
jq -r '.actionHistory[:5][] | "  [\(.timestamp)] \(.action)\(if .skipped then " (skipped)" else "" end) — \(.note)"' "$STATE_FILE" 2>/dev/null
if [ "$(jq '.actionHistory | length' "$STATE_FILE")" -eq 0 ]; then
    echo "  (none yet)"
fi
