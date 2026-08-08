#!/bin/bash
# generate-dashboard.sh — Write PFC's own dashboard fragment, then call the
# shared dashboard-builder.sh. Reads ONLY PFC's own state file (its decide.sh
# cross-reads siblings for arbitration, but the dashboard tab does not).
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No PFC state found"; exit 1; }

LOAD=$(jq -r '.executiveLoad' "$STATE_FILE")
GOALS=$(jq -c '[.goals[] | select(.status=="active") | {description, priority}]' "$STATE_FILE")
INHIBITIONS=$(jq -c '[.inhibitions[] | {pattern, reason}]' "$STATE_FILE")
DECISIONS=$(jq -c '[.decisionLog[:6][] | {context, chosen, reasoning}]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="card-title">Executive Load</div>
            <div class="dim"><span class="dim-icon">🧭</span><span class="dim-name">Load</span><div class="dim-bar"><div class="dim-fill" id="loadFill" style="width:0%;background:#a855f7"></div></div><span class="dim-val" id="loadVal">0.00</span></div>
        </div>
        <div class="card"><div class="card-title">Active Goals</div><div id="goalList"></div></div>
        <div class="card"><div class="card-title">Inhibitions</div><div id="inhibitionList" class="tags"></div></div>
        <div class="card"><div class="card-title">Recent Decisions</div><div id="decisionList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.prefrontal;
  const load = s.executiveLoad || 0;
  document.getElementById('loadFill').style.width = Math.round(load*100) + '%';
  document.getElementById('loadVal').textContent = load.toFixed(2);

  const goalEl = document.getElementById('goalList');
  if (s.goals && s.goals.length) {
    s.goals.sort((a,b) => (b.priority||0) - (a.priority||0)).forEach(g => {
      goalEl.innerHTML += `<div class="list-item"><span class="badge">${Math.round((g.priority||0.5)*100)}%</span><span class="list-text">${g.description}</span></div>`;
    });
  } else {
    goalEl.innerHTML = '<div class="empty">No active goals</div>';
  }

  const inhEl = document.getElementById('inhibitionList');
  if (s.inhibitions && s.inhibitions.length) {
    s.inhibitions.forEach(i => { inhEl.innerHTML += `<span class="sup-tag" title="${i.reason||''}">🚫 ${i.pattern}</span>`; });
  } else {
    inhEl.innerHTML = '<div class="empty">No active inhibitions</div>';
  }

  const decEl = document.getElementById('decisionList');
  if (s.decisions && s.decisions.length) {
    s.decisions.forEach(d => {
      decEl.innerHTML += `<div class="list-item"><span class="badge">${d.context||'general'}</span><div><span class="list-text">chose <strong>${d.chosen||'—'}</strong></span><div class="list-sub">${d.reasoning||''}</div></div></div>`;
    });
  } else {
    decEl.innerHTML = '<div class="empty">No decisions logged yet</div>';
  }
})();
SCRIPTEOF
)

DATA_JSON=$(jq -n --argjson load "$LOAD" --argjson goals "$GOALS" --argjson inhibitions "$INHIBITIONS" --argjson decisions "$DECISIONS" \
  --arg lastUpdated "$(jq -r '.lastUpdated // "never"' "$STATE_FILE")" --arg lastConsultedAt "$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")" \
  '{installed: true, executiveLoad: $load, goals: $goals, inhibitions: $inhibitions, decisions: $decisions, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/pfc_frag_html.$$
echo "$SCRIPT" > /tmp/pfc_frag_script.$$
jq -n --arg id "prefrontal" --argjson order 15 --arg label "Executive" --arg icon "🧭" \
  --rawfile html /tmp/pfc_frag_html.$$ --rawfile script /tmp/pfc_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/prefrontal.json"
rm -f /tmp/pfc_frag_html.$$ /tmp/pfc_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus prefrontal
