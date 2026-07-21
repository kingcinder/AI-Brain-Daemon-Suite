#!/bin/bash
# generate-dashboard.sh — Write social-memory's own dashboard fragment, then
# call the shared dashboard-builder.sh. Reads ONLY social-memory's own state.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/social-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

TOP_RELATIONSHIPS=$(jq -c '[.relationships | to_entries | sort_by(.value.lastContact) | reverse | .[:6] | .[] | {id: .key, name: .value.name, type: .value.type, trust: .value.trust, affinity: .value.affinity}]' "$STATE_FILE")
OPEN_LOOPS=$(jq -c '[.relationships | to_entries[] | .value.name as $name | .value.openLoops[] | select(.status=="open") | {name: $name, description}] | .[:8]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="stats-3">
                <div class="stat"><div class="stat-val-sm" id="relCount">0</div><div class="stat-label">Relationships</div></div>
                <div class="stat"><div class="stat-val-sm" id="humanCount">0</div><div class="stat-label">Humans</div></div>
                <div class="stat"><div class="stat-val-sm" id="agentCount">0</div><div class="stat-label">AI Agents</div></div>
            </div>
        </div>
        <div class="card"><div class="card-title">Recent Contacts</div><div id="relList"></div></div>
        <div class="card"><div class="card-title">Open Loops</div><div id="loopList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.social;
  document.getElementById('relCount').textContent = (s.relationships || []).length;
  document.getElementById('humanCount').textContent = (s.relationships || []).filter(r => r.type === 'human').length;
  document.getElementById('agentCount').textContent = (s.relationships || []).filter(r => r.type === 'ai_agent').length;

  const relEl = document.getElementById('relList');
  if (s.relationships && s.relationships.length) {
    s.relationships.forEach(r => {
      relEl.innerHTML += `<div class="dim"><span class="dim-icon">${r.type === 'ai_agent' ? '🤖' : '🧑'}</span><span class="dim-name">${r.name}</span><div class="dim-bar"><div class="dim-fill" style="width:${Math.round((r.trust||0.5)*100)}%;background:#10b981"></div></div><span class="dim-val">${(r.trust||0.5).toFixed(2)}</span></div>`;
    });
  } else {
    relEl.innerHTML = '<div class="empty">No relationships recorded yet</div>';
  }

  const loopEl = document.getElementById('loopList');
  if (s.openLoops && s.openLoops.length) {
    s.openLoops.forEach(l => { loopEl.innerHTML += `<div class="flag-item"><strong>${l.name}</strong> — ${l.description}</div>`; });
  } else {
    loopEl.innerHTML = '<div class="empty">Nothing pending</div>';
  }
})();
SCRIPTEOF
)

DATA_JSON=$(jq -n --argjson relationships "$TOP_RELATIONSHIPS" --argjson openLoops "$OPEN_LOOPS" \
  --arg lastUpdated "$(jq -r '.lastUpdated // "never"' "$STATE_FILE")" --arg lastConsultedAt "$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")" \
  '{installed: true, relationships: $relationships, openLoops: $openLoops, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/social_frag_html.$$
echo "$SCRIPT" > /tmp/social_frag_script.$$
jq -n --arg id "social" --argjson order 85 --arg label "Social" --arg icon "🫂" \
  --rawfile html /tmp/social_frag_html.$$ --rawfile script /tmp/social_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/social.json"
rm -f /tmp/social_frag_html.$$ /tmp/social_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus social
