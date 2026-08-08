#!/bin/bash
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"
exec 200>"$STATE_FILE.lock"
flock 200
[ ! -f "$STATE_FILE" ] && { echo "❌ No PFC state found"; exit 1; }
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
[ "$1" = "--json" ] && { cat "$STATE_FILE"; exit 0; }

LOAD=$(jq -r '.executiveLoad' "$STATE_FILE")
ACTIVE_GOALS=$(jq '[.goals[] | select(.status=="active")] | length' "$STATE_FILE")
INHIBITIONS=$(jq '.inhibitions | length' "$STATE_FILE")
DECISIONS=$(jq '.decisionLog | length' "$STATE_FILE")

echo "🧭 Prefrontal Cortex State"
echo "─────────────────────────"
echo "Executive load:    $LOAD"
echo "Active goals:      $ACTIVE_GOALS"
echo "Inhibitions:       $INHIBITIONS"
echo "Decisions logged:  $DECISIONS"
echo ""
echo "Recent decisions:"
jq -r '.decisionLog[:5][] | "  [\(.timestamp // "—")] \(.context // "general"): chose \(.chosen // "—") — \(.reasoning // "")"' "$STATE_FILE" 2>/dev/null
[ "$DECISIONS" -eq 0 ] && echo "  (none yet)"
