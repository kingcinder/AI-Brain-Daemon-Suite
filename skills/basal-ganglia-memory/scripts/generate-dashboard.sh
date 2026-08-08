#!/bin/bash
# generate-dashboard.sh — Write basal ganglia's own dashboard fragment, then
# call the shared dashboard-builder.sh. Reads ONLY its own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No basal ganglia state found"; exit 1; }

CHUNKED_COUNT=$(jq '[.habits // [] | .[] | select(.status=="chunked")] | length' "$STATE_FILE")
HABIT_COUNT=$(jq '.habits // [] | length' "$STATE_FILE")
PROCEDURE_COUNT=$(jq '.procedures // [] | length' "$STATE_FILE")
SUPPRESSION_COUNT=$(jq '.suppressions // [] | length' "$STATE_FILE")
HABIT_BARS=$(jq -c '[.habits // [] | sort_by(-.strength) | .[:8] | .[] | {cue: .cue, strength: .strength}]' "$STATE_FILE")
PROCS=$(jq -c '[.procedures // [] | .[:8] | .[] | {name: .name, steps: (.steps // [])}]' "$STATE_FILE")
SUPPS=$(jq -c '[.suppressions // [] | .[] | (.pattern // tostring)]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="stats-4">
          <div class="stat"><div class="stat-val-sm" id="chunkedCount">0</div><div class="stat-label">🟢 Chunked</div></div>
          <div class="stat"><div class="stat-val-sm" id="habitCount">0</div><div class="stat-label">Habits</div></div>
          <div class="stat"><div class="stat-val-sm" id="procCount">0</div><div class="stat-label">Procedures</div></div>
          <div class="stat"><div class="stat-val-sm" id="suppCount">0</div><div class="stat-label">🚫 Suppressed</div></div>
        </div></div>
        <div class="card"><div class="card-title">Habits by Strength</div><div id="habitBars"></div></div>
        <div class="card"><div class="card-title">Procedures</div><div id="procList"></div></div>
        <div class="card"><div class="card-title">Suppressions</div><div id="suppList" class="tags"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.basal;
  document.getElementById('chunkedCount').textContent = s.chunkedCount;
  document.getElementById('habitCount').textContent = s.habitCount;
  document.getElementById('procCount').textContent = s.procedureCount;
  document.getElementById('suppCount').textContent = s.suppressionCount;
  const hb = document.getElementById('habitBars');
  if (s.habitBars && s.habitBars.length) {
    s.habitBars.forEach(h => {
      hb.innerHTML += `<div class="dim"><span class="dim-name">${h.cue}</span><div class="dim-bar"><div class="dim-fill" style="width:${Math.round(h.strength*100)}%"></div></div><span class="dim-val">${h.strength.toFixed(2)}</span></div>`;
    });
  } else { hb.innerHTML = '<div class="empty">No habits tracked yet.</div>'; }
  const pl = document.getElementById('procList');
  if (s.procedures && s.procedures.length) {
    s.procedures.forEach(p => pl.innerHTML += `<div class="list-item"><div class="list-text">${p.name}</div><div class="list-sub">${(p.steps||[]).join(' → ')}</div></div>`);
  } else { pl.innerHTML = '<div class="empty">No procedures yet.</div>'; }
  const sl = document.getElementById('suppList');
  (s.suppressions || []).forEach(x => sl.innerHTML += `<span class="tag">${x}</span>`);
  if (!(s.suppressions || []).length) sl.innerHTML = '<div class="empty">Nothing suppressed.</div>';
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson chunkedCount "$CHUNKED_COUNT" --argjson habitCount "$HABIT_COUNT" \
  --argjson procedureCount "$PROCEDURE_COUNT" --argjson suppressionCount "$SUPPRESSION_COUNT" \
  --argjson habitBars "$HABIT_BARS" --argjson procedures "$PROCS" --argjson suppressions "$SUPPS" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, chunkedCount: $chunkedCount, habitCount: $habitCount, procedureCount: $procedureCount, suppressionCount: $suppressionCount, habitBars: $habitBars, procedures: $procedures, suppressions: $suppressions, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/basal_frag_html.$$
echo "$SCRIPT" > /tmp/basal_frag_script.$$
jq -n --arg id "basal" --argjson order 40 --arg label "Habits" --arg icon "🎯" \
  --rawfile html /tmp/basal_frag_html.$$ --rawfile script /tmp/basal_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/basal.json"
rm -f /tmp/basal_frag_html.$$ /tmp/basal_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus basal
