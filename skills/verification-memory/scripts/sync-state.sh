#!/bin/bash
# sync-state.sh — Regenerate VERIFICATION_STATE.md + dashboard fragment from
# verification-state.json. Reads ONLY this skill's own state file.
set -u

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$WORKSPACE/memory/verification-state.json"
MD_FILE="$WORKSPACE/VERIFICATION_STATE.md"

if [ ! -f "$STATE_FILE" ]; then
    echo "No verification-state.json found"
    exit 0
fi

LAST_RUN=$(jq -r '.lastRun // "never"' "$STATE_FILE")
TOTAL=$(jq -r '.totals.tests // 0' "$STATE_FILE")
PASSED=$(jq -r '.totals.passed // 0' "$STATE_FILE")
FAILED=$(jq -r '.totals.failed // 0' "$STATE_FILE")
FILTER=$(jq -r '.moduleFilter // "all"' "$STATE_FILE")

# Long-term health: per-module pass-rate history (best effort — no ledger → skip)
HISTORY_JSON=$("$SCRIPT_DIR/query-history.sh" --limit 8 2>/dev/null || echo '{}')
HAS_MODULES=$(echo "$HISTORY_JSON" | jq -r 'if (.modules | length) > 0 then "yes" else "no" end' 2>/dev/null || echo no)

{
    echo "# Verification State — $LAST_RUN UTC"
    echo ""
    echo "**Scope:** ${FILTER}"
    echo ""
    echo "| Result | Count |"
    echo "|--------|-------|"
    echo "| ✅ Passed | $PASSED |"
    echo "| ❌ Failed | $FAILED |"
    echo "| Total | $TOTAL |"
    echo ""
    if [ "$FAILED" -gt 0 ]; then
        echo "## 🔴 Failures"
        echo ""
        jq -r '.lastFailure[]? | "- `\(.)`"' "$STATE_FILE"
        echo ""
    else
        echo "## ✨ All declared tests green"
        echo ""
    fi
    if [ "$HAS_MODULES" = "yes" ]; then
        echo "## 📈 Long-Term Health (last 8 runs)"
        echo ""
        echo "| Region | Pass Rate | Runs |"
        echo "|--------|-----------|------|"
        echo "$HISTORY_JSON" | jq -r '.modules[] | "| \(.module) | \((.pass_rate * 100 | round))% | \(.runs) |"'
        echo ""
        echo "🏆 Healthiest: $(echo "$HISTORY_JSON" | jq -r '.healthiest.module // "n/a"') · $(echo "$HISTORY_JSON" | jq -r '((.healthiest.pass_rate // 0) * 100 | round)')%"
        echo "🚨 Unhealthiest: $(echo "$HISTORY_JSON" | jq -r '.unhealthiest.module // "n/a"') · $(echo "$HISTORY_JSON" | jq -r '((.unhealthiest.pass_rate // 0) * 100 | round)')%"
        echo ""
    fi
} > "$MD_FILE"

echo "✅ VERIFICATION_STATE.md updated"

# Regenerate the dashboard fragment
[ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true
