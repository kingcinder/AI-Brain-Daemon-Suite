#!/bin/bash
# generate-dashboard.sh — Write ACC-conflict's own dashboard fragment, then
# call the shared dashboard-builder.sh. Reads ONLY its own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No ACC-conflict state found"; exit 1; }

LOAD=$(jq -r '.conflictLoad // 0' "$STATE_FILE")
ACTIVE_COUNT=$(jq '.activeConflicts // {} | length' "$STATE_FILE")
FLAGS=$(jq -c '[.attentionFlags // [] | .[] | (.label // .reason // tostring)]' "$STATE_FILE")
CONFLICTS=$(jq -c '[.activeConflicts // {} | to_entries | .[:8] | .[] | {topic: .key, detail: (.value.detail // .value.description // "")}]' "$STATE_FILE")

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
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, conflictLoad: $conflictLoad, activeCount: $activeCount, attentionFlags: $attentionFlags, conflicts: $conflicts, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/accc_frag_html.$$
echo "$SCRIPT" > /tmp/accc_frag_script.$$
jq -n --arg id "acc_conflict" --argjson order 60 --arg label "Conflicts" --arg icon "⚡" \
  --rawfile html /tmp/accc_frag_html.$$ --rawfile script /tmp/accc_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/acc_conflict.json"
rm -f /tmp/accc_frag_html.$$ /tmp/accc_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus acc_conflict
