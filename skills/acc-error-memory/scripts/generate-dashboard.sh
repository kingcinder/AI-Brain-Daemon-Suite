#!/bin/bash
# generate-dashboard.sh — Write ACC-error's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY its own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/acc-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No ACC-error state found"; exit 1; }

ACTIVE_COUNT=$(jq '.activePatterns // {} | length' "$STATE_FILE")
RESOLVED_COUNT=$(jq '.resolved // [] | length' "$STATE_FILE")
PATTERNS=$(jq -c '[.activePatterns // {} | to_entries | .[:8] | .[] | {pattern: .key, count: .value.count, severity: (.value.severity // "normal")}]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="stats">
          <div class="stat"><div class="stat-val" id="activeCount">0</div><div class="stat-label">Active Patterns</div></div>
          <div class="stat"><div class="stat-val" id="resolvedCount">0</div><div class="stat-label">Resolved</div></div>
        </div></div>
        <div class="card"><div class="card-title">Active Error Patterns</div><div id="patternList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.acc_error;
  document.getElementById('activeCount').textContent = s.activeCount;
  document.getElementById('resolvedCount').textContent = s.resolvedCount;
  const el = document.getElementById('patternList');
  if (s.patterns && s.patterns.length) {
    s.patterns.forEach(p => {
      el.innerHTML += `<div class="list-item"><div class="list-text">${p.pattern}</div><div class="list-sub">${p.count}x · ${p.severity}</div></div>`;
    });
  } else {
    el.innerHTML = '<div class="empty">No active error patterns.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson activeCount "$ACTIVE_COUNT" --argjson resolvedCount "$RESOLVED_COUNT" --argjson patterns "$PATTERNS" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, activeCount: $activeCount, resolvedCount: $resolvedCount, patterns: $patterns, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/acce_frag_html.$$
echo "$SCRIPT" > /tmp/acce_frag_script.$$
jq -n --arg id "acc_error" --argjson order 50 --arg label "Errors" --arg icon "🔴" \
  --rawfile html /tmp/acce_frag_html.$$ --rawfile script /tmp/acce_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/acc_error.json"
rm -f /tmp/acce_frag_html.$$ /tmp/acce_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus acc_error
