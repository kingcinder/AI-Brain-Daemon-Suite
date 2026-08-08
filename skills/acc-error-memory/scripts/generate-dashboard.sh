#!/bin/bash
# generate-dashboard.sh — Write ACC-error's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY its own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/acc-state.json"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No ACC-error state found"; exit 1; }

ACTIVE_COUNT=$(jq '.activePatterns // {} | length' "$STATE_FILE")
RESOLVED_COUNT=$(jq '.resolved // [] | length' "$STATE_FILE")
PATTERNS=$(jq -c '[.activePatterns // {} | to_entries | .[:8] | .[] | {pattern: .key, count: .value.count, severity: (.value.severity // "normal")}]' "$STATE_FILE")

# Calibration signal: how often did anterior-cingulate conflict flags predict
# MY error corrections? Shared core/self-mod/acc-calibration.sh; degrades to zeros.
CALIBRATION='{"total_conflicts":0,"flags_followed_by_error":0,"hit_rate":0.0,"false_positive_rate":0.0,"by_type":{}}'
if [ -x "$ROOT/core/self-mod/acc-calibration.sh" ]; then
  CAL_JSON=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/self-mod/acc-calibration.sh" 2>/dev/null) && \
    echo "$CAL_JSON" | jq empty >/dev/null 2>&1 && CALIBRATION="$CAL_JSON"
fi

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="stats">
          <div class="stat"><div class="stat-val" id="activeCount">0</div><div class="stat-label">Active Patterns</div></div>
          <div class="stat"><div class="stat-val" id="resolvedCount">0</div><div class="stat-label">Resolved</div></div>
        </div></div>
        <div class="card"><div class="card-title">🎯 Flag→Error Calibration</div>
          <div class="stats">
            <div class="stat"><div class="stat-val" id="errCalibHitRate">—</div><div class="stat-label">Flags Predicting Errors</div></div>
            <div class="stat"><div class="stat-val" id="errCalibPredicted">0</div><div class="stat-label">Unpredicted Errors</div></div>
          </div>
          <div id="errCalibTypeList" class="steps" style="margin-top:10px"></div>
        </div>
        <div class="card"><div class="card-title">Active Error Patterns</div><div id="patternList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.acc_error;
  document.getElementById('activeCount').textContent = s.activeCount;
  document.getElementById('resolvedCount').textContent = s.resolvedCount;
  const cal = s.calibration || {};
  const hrEl = document.getElementById('errCalibHitRate');
  if (hrEl) {
    const total = cal.total_conflicts || 0;
    const hits = cal.flags_followed_by_error || 0;
    hrEl.textContent = total ? hits + '/' + total + ' (' + Math.round((cal.hit_rate || 0) * 100) + '%)' : '—';
  }
  const upEl = document.getElementById('errCalibPredicted');
  if (upEl) upEl.textContent = cal.errors_unpredicted || 0;
  const tl = document.getElementById('errCalibTypeList');
  if (tl) {
    const types = Object.keys(cal.by_type || {});
    if (!types.length) tl.innerHTML = '<div class="empty">No flagged conflicts to calibrate yet.</div>';
    else tl.innerHTML = types.map(t => {
      const v = cal.by_type[t];
      return '· ' + t + ': ' + (v.hits || 0) + '/' + (v.total || 0) + ' (' + Math.round((v.hit_rate || 0) * 100) + '%)';
    }).join('<br>');
  }
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
  --argjson calibration "$CALIBRATION" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, activeCount: $activeCount, resolvedCount: $resolvedCount, patterns: $patterns, calibration: $calibration, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/acce_frag_html.$$
echo "$SCRIPT" > /tmp/acce_frag_script.$$
jq -n --arg id "acc_error" --argjson order 50 --arg label "Errors" --arg icon "🔴" \
  --rawfile html /tmp/acce_frag_html.$$ --rawfile script /tmp/acce_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/acc_error.json"
rm -f /tmp/acce_frag_html.$$ /tmp/acce_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus acc_error
