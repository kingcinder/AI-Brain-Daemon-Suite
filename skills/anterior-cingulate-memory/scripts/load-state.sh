#!/usr/bin/env bash
# scripts/load-state.sh — Human-readable conflict state for session context

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "⚡ No conflict state found. Run ./install.sh first." >&2
  exit 1
fi

LOAD=$(jq -r '.conflictLoad' "$STATE_FILE")
ACTIVE=$(jq '.activeConflicts | length' "$STATE_FILE")
FLAGS=$(jq '.attentionFlags | length' "$STATE_FILE")
ZONES=$(jq '.uncertaintyZones | length' "$STATE_FILE")
TOTAL_LOGGED=$(jq '.stats.totalConflictsLogged' "$STATE_FILE")
TOTAL_RESOLVED=$(jq '.stats.totalResolved' "$STATE_FILE")
UPDATED=$(jq -r '.lastUpdated' "$STATE_FILE")

# ── Determine load status ─────────────────────────────────────────────────────
LOAD_NUM=$(echo "$LOAD" | awk '{printf "%.4f", $1}')
if   awk "BEGIN{exit !($LOAD_NUM < 0.2)}";  then STATUS="🟢 clear — proceed normally"
elif awk "BEGIN{exit !($LOAD_NUM < 0.4)}";  then STATUS="🟡 low — minor ambiguities present"
elif awk "BEGIN{exit !($LOAD_NUM < 0.6)}";  then STATUS="🟠 moderate — verify key claims"
elif awk "BEGIN{exit !($LOAD_NUM < 0.8)}";  then STATUS="🔴 elevated — ask before proceeding"
else                                              STATUS="🚨 critical — explicit caution required"
fi

echo "⚡ Anterior Cingulate (Conflict State)"
echo "   Conflict load: $LOAD_NUM ($STATUS)"
echo "   Active conflicts: $ACTIVE"
echo "   Attention flags:  $FLAGS"
echo "   Uncertainty zones: $ZONES"
echo "   Lifetime: $TOTAL_LOGGED logged, $TOTAL_RESOLVED resolved"
echo "   Updated: $UPDATED"

# ── Active conflicts detail ───────────────────────────────────────────────────
if [[ "$ACTIVE" -gt 0 ]]; then
  echo ""
  echo "   ── Active Conflicts ──"
  jq -r '
    .activeConflicts | to_entries[] |
    "   • [\(.value.type)/\(.value.severity)] \(.value.description)" +
    (if .value.resolutionHint != "" then "\n     → \(.value.resolutionHint)" else "" end)
  ' "$STATE_FILE"
fi

# ── Attention flags detail ────────────────────────────────────────────────────
if [[ "$FLAGS" -gt 0 ]]; then
  echo ""
  echo "   ── Attention Flags ──"
  jq -r '.attentionFlags[] | "   📌 \(.topic): \(.reason)"' "$STATE_FILE"
fi

# ── Uncertainty zones detail ──────────────────────────────────────────────────
if [[ "$ZONES" -gt 0 ]]; then
  echo ""
  echo "   ── Uncertainty Zones ──"
  jq -r '
    .uncertaintyZones | to_entries[] |
    "   ⚠️  \(.key) (level: \(.value.level)): \(.value.reason)"
  ' "$STATE_FILE"
fi

# Best-effort staleness tracking: record that this state was actually read,
# separate from lastUpdated (write path). Never blocks or fails the output above.
exec 200>"$STATE_FILE.lock"
flock 200
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
