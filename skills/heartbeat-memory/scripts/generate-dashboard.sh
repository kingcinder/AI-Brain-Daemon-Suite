#!/bin/bash
# generate-dashboard.sh — Write heartbeat's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY heartbeat's own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No heartbeat state found"; exit 1; }

BEAT_COUNT=$(jq -r '.beatCount' "$STATE_FILE")
LAST_ACTION=$(jq -r '.lastChosenAction // "—"' "$STATE_FILE")
LAST_BEAT=$(jq -r '.lastBeat // "never"' "$STATE_FILE")
RECENT_ACTIONS=$(jq -c '[.actionHistory[:6][] | {action, note, skipped, timestamp}]' "$STATE_FILE")
TOP_PROJECTS=$(jq -c '[.projects[] | select(.status=="active") | {id, title, type, note}]' "$STATE_FILE")
OPTIONS=$(jq -c '[.options | to_entries[] | {id: .key, label: .value.label, weight: .value.weight}]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="stats-3">
                <div class="stat"><div class="stat-val-sm" id="beatCount">0</div><div class="stat-label">Beats</div></div>
                <div class="stat"><div class="stat-val-sm" id="lastAction">—</div><div class="stat-label">Last Action</div></div>
                <div class="stat"><div class="stat-val-sm" id="activeProjects">0</div><div class="stat-label">Active Projects</div></div>
            </div>
            <div class="list-sub" id="lastBeatTime" style="text-align:center; margin-top:8px;"></div>
        </div>
        <div class="card"><div class="card-title">Active Projects</div><div id="projectList"></div></div>
        <div class="card"><div class="card-title">Recent Beats</div><div id="actionList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.heartbeat;
  document.getElementById('beatCount').textContent = s.beatCount || 0;
  document.getElementById('lastAction').textContent = s.lastAction || '—';
  document.getElementById('activeProjects').textContent = (s.projects || []).length;
  document.getElementById('lastBeatTime').textContent = 'Last beat: ' + (s.lastBeat || 'never');

  const projEl = document.getElementById('projectList');
  if (s.projects && s.projects.length) {
    s.projects.forEach(p => {
      projEl.innerHTML += `<div class="list-item"><span class="badge">${p.type}</span><span class="list-text">${p.title}${p.note ? ' — ' + p.note : ''}</span></div>`;
    });
  } else {
    projEl.innerHTML = '<div class="empty">No active projects registered</div>';
  }

  const actEl = document.getElementById('actionList');
  if (s.recentActions && s.recentActions.length) {
    s.recentActions.forEach(a => {
      const badge = a.skipped ? '<span class="badge">skipped</span>' : `<span class="badge badge-chunked">${a.action}</span>`;
      actEl.innerHTML += `<div class="list-item">${badge}<span class="list-text">${a.note || ''}</span></div>`;
    });
  } else {
    actEl.innerHTML = '<div class="empty">No beats logged yet</div>';
  }
})();
SCRIPTEOF
)

DATA_JSON=$(jq -n \
  --argjson beatCount "$BEAT_COUNT" --arg lastAction "$LAST_ACTION" --arg lastBeat "$LAST_BEAT" \
  --argjson projects "$TOP_PROJECTS" --argjson recentActions "$RECENT_ACTIONS" --argjson options "$OPTIONS" \
  --arg lastUpdated "$(jq -r '.lastUpdated // "never"' "$STATE_FILE")" --arg lastConsultedAt "$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")" \
  '{installed: true, beatCount: $beatCount, lastAction: $lastAction, lastBeat: $lastBeat, projects: $projects, recentActions: $recentActions, options: $options, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/heartbeat_frag_html.$$
echo "$SCRIPT" > /tmp/heartbeat_frag_script.$$

jq -n \
  --arg id "heartbeat" --argjson order 75 --arg label "Pulse" --arg icon "💓" \
  --rawfile html /tmp/heartbeat_frag_html.$$ --rawfile script /tmp/heartbeat_frag_script.$$ \
  --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/heartbeat.json"

rm -f /tmp/heartbeat_frag_html.$$ /tmp/heartbeat_frag_script.$$
"$SCRIPT_DIR/dashboard-builder.sh" --focus heartbeat
