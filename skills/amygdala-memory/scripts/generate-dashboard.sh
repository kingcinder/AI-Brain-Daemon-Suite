#!/bin/bash
# generate-dashboard.sh — Write amygdala's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY amygdala's own state file.
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/emotional-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No amygdala state found"; exit 1; }

DIMS=$(jq -c '.dimensions // {}' "$STATE_FILE")
RECENT=$(jq -c '[.recentEmotions // [] | .[-6:] | .[] | {label: (.label // .emotion // "feeling"), intensity: (.intensity // 0)}]' "$STATE_FILE")
SALIENCE=$(jq -c '[.salienceTags // [] | .[-6:] | .[] | {emotion, salience, trigger: (.trigger // "")}]' "$STATE_FILE")
LAST_SALIENCE=$(jq -c '.lastSalience // null' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="card-title">Dimensions</div><div id="dimensions"></div></div>
        <div class="card"><div class="card-title">Mood Quadrant</div>
          <div class="quadrant">
            <div class="q-cell" id="q-stressed">😤 Stressed</div>
            <div class="q-cell" id="q-energized">😄 Energized</div>
            <div class="q-cell" id="q-depleted">😔 Depleted</div>
            <div class="q-cell" id="q-content">😌 Content</div>
          </div>
        </div>
        <div class="card"><div class="card-title">Recent Feelings</div><div id="recentEmotions"></div></div>
        <div class="card"><div class="card-title">Salience Tags (threat/importance)</div><div id="salienceList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.amygdala;
  const el = document.getElementById('dimensions');
  const dims = s.dimensions || {};
  Object.keys(dims).forEach(k => {
    const v = dims[k];
    el.innerHTML += `<div class="dim"><span class="dim-name">${k}</span><div class="dim-bar"><div class="dim-fill" style="width:${Math.round(v*100)}%"></div></div><span class="dim-val">${v.toFixed(2)}</span></div>`;
  });
  const valence = dims.valence || 0, arousal = dims.arousal || 0;
  const quad = arousal >= 0.5 ? (valence >= 0 ? 'q-energized' : 'q-stressed') : (valence >= 0 ? 'q-content' : 'q-depleted');
  const qc = document.getElementById(quad);
  if (qc) qc.classList.add('active');
  const re = document.getElementById('recentEmotions');
  if (s.recentEmotions && s.recentEmotions.length) {
    s.recentEmotions.forEach(e => {
      re.innerHTML += `<div class="list-item"><div class="list-text">${e.label}</div><div class="list-sub">intensity ${e.intensity.toFixed(2)}</div></div>`;
    });
  } else {
    re.innerHTML = '<div class="empty">No recent emotions logged.</div>';
  }
  const sl = document.getElementById('salienceList');
  if (s.salienceTags && s.salienceTags.length) {
    s.salienceTags.slice().reverse().forEach(t => {
      sl.innerHTML += `<div class="list-item"><div class="badge badge-critical">${t.salience.toFixed(2)}</div><div class="list-text">${t.emotion}</div><div class="list-sub">${t.trigger || 'salience-tagged event'}</div></div>`;
    });
  } else {
    sl.innerHTML = '<div class="empty">No high-salience events tagged yet.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson dimensions "$DIMS" --argjson recentEmotions "$RECENT" --argjson salienceTags "$SALIENCE" --argjson lastSalience "$LAST_SALIENCE" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, dimensions: $dimensions, recentEmotions: $recentEmotions, salienceTags: $salienceTags, lastSalience: $lastSalience, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/amy_frag_html.$$
echo "$SCRIPT" > /tmp/amy_frag_script.$$
jq -n --arg id "amygdala" --argjson order 20 --arg label "Emotions" --arg icon "🎭" \
  --rawfile html /tmp/amy_frag_html.$$ --rawfile script /tmp/amy_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/amygdala.json"
rm -f /tmp/amy_frag_html.$$ /tmp/amy_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus amygdala
