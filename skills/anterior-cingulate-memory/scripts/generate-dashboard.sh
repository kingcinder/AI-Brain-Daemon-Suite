#!/bin/bash
# generate-dashboard.sh — Write ACC-conflict's own dashboard fragment, then
# call the shared dashboard-builder.sh. Reads ONLY its own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No ACC-conflict state found"; exit 1; }

LOAD=$(jq -r '.conflictLoad // 0' "$STATE_FILE")
ACTIVE_COUNT=$(jq '.activeConflicts // {} | length' "$STATE_FILE")
FLAGS=$(jq -c '[.attentionFlags // [] | .[] | (.label // .reason // tostring)]' "$STATE_FILE")
CONFLICTS=$(jq -c '[.activeConflicts // {} | to_entries | .[:8] | .[] | {topic: .key, detail: (.value.detail // .value.description // "")}]' "$STATE_FILE")

# Calibration signal: how often do MY conflict flags predict an actual acc-error
# correction? Shared core/self-mod/acc-calibration.sh; degrades to zeros.
CALIBRATION='{"total_conflicts":0,"flags_followed_by_error":0,"hit_rate":0.0,"false_positive_rate":0.0,"by_type":{}}'
if [ -x "$ROOT/core/self-mod/acc-calibration.sh" ]; then
  CAL_JSON=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/self-mod/acc-calibration.sh" 2>/dev/null) && \
    echo "$CAL_JSON" | jq empty >/dev/null 2>&1 && CALIBRATION="$CAL_JSON"
fi

HTML=$(cat << 'HTMLEOF'
        <div class="card">
          <div class="drive-meter" style="padding:16px">
            <div class="drive-val" id="conflictStatus">OK</div>
            <div class="drive-label">Conflict Load: <span id="conflictPct">0%</span></div>
            <div class="drive-bar"><div class="drive-fill" id="conflictFill" style="width:0%"></div></div>
          </div>
        </div>
        <div class="card"><div class="stats">
          <div class="stat"><div class="stat-val" id="activeConflicts">0</div><div class="stat-label">Active Conflicts</div></div>
        </div></div>
        <div class="card"><div class="card-title">🎯 Flag→Error Calibration</div>
          <div class="stats">
            <div class="stat"><div class="stat-val" id="calibHitRate">—</div><div class="stat-label">Flags Predicting Errors</div></div>
            <div class="stat"><div class="stat-val" id="calibFlags">0</div><div class="stat-label">Total Flags</div></div>
          </div>
          <div id="calibTypeList" class="steps" style="margin-top:10px"></div>
        </div>
        <div class="card"><div class="card-title">Attention Flags</div><div id="attentionFlags" class="tags"></div></div>
        <div class="card"><div class="card-title">Active Conflicts</div><div id="conflictList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.acc_conflict;
  const pct = Math.round((s.conflictLoad || 0) * 100);
  document.getElementById('conflictPct').textContent = pct + '%';
  document.getElementById('conflictFill').style.width = pct + '%';
  document.getElementById('conflictStatus').textContent = pct >= 60 ? 'Elevated' : pct >= 30 ? 'Moderate' : 'OK';
  document.getElementById('activeConflicts').textContent = s.activeCount;
  const cal = s.calibration || {};
  const hitRateEl = document.getElementById('calibHitRate');
  if (hitRateEl) {
    const total = cal.total_conflicts || 0;
    const hits = cal.flags_followed_by_error || 0;
    hitRateEl.textContent = total ? hits + '/' + total : '—';
  }
  const calFlagsEl = document.getElementById('calibFlags');
  if (calFlagsEl) calFlagsEl.textContent = cal.total_conflicts || 0;
  const tl = document.getElementById('calibTypeList');
  if (tl) {
    const types = Object.keys(cal.by_type || {});
    if (!types.length) tl.innerHTML = '<div class="empty">No flagged conflicts to calibrate yet.</div>';
    else tl.innerHTML = types.map(t => {
      const v = cal.by_type[t];
      return '· ' + t + ': ' + (v.hits || 0) + '/' + (v.total || 0) + ' (' + Math.round((v.hit_rate || 0) * 100) + '%)';
    }).join('<br>');
  }
  const fl = document.getElementById('attentionFlags');
  (s.attentionFlags || []).forEach(f => fl.innerHTML += `<span class="tag">${f}</span>`);
  if (!(s.attentionFlags || []).length) fl.innerHTML = '<div class="empty">No attention flags.</div>';
  const cl = document.getElementById('conflictList');
  if (s.conflicts && s.conflicts.length) {
    s.conflicts.forEach(c => cl.innerHTML += `<div class="list-item"><div class="list-text">${c.topic}</div><div class="list-sub">${c.detail}</div></div>`);
  } else {
    cl.innerHTML = '<div class="empty">No active conflicts.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson conflictLoad "$LOAD" --argjson activeCount "$ACTIVE_COUNT" --argjson attentionFlags "$FLAGS" --argjson conflicts "$CONFLICTS" \
  --argjson calibration "$CALIBRATION" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, conflictLoad: $conflictLoad, activeCount: $activeCount, attentionFlags: $attentionFlags, conflicts: $conflicts, calibration: $calibration, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/accc_frag_html.$$
echo "$SCRIPT" > /tmp/accc_frag_script.$$
jq -n --arg id "acc_conflict" --argjson order 60 --arg label "Conflicts" --arg icon "⚡" \
  --rawfile html /tmp/accc_frag_html.$$ --rawfile script /tmp/accc_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/acc_conflict.json"
rm -f /tmp/accc_frag_html.$$ /tmp/accc_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus acc_conflict
