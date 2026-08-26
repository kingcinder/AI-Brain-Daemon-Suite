#!/bin/bash
# generate-dashboard.sh — Write cerebellum's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY cerebellum's own state file.
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No cerebellum state found"; exit 1; }

GLOBAL=$(jq -r '.globalCalibration' "$STATE_FILE")
SKILLS=$(jq -c '[.skills | to_entries | sort_by(-.value.precision) | .[:8] | .[] | {name: .key, precision: .value.precision, smoothness: .value.smoothness, reps: .value.reps, predictionError: .value.predictionError}]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="dim"><span class="dim-icon">🎚️</span><span class="dim-name">Global Calibration</span><div class="dim-bar"><div class="dim-fill" id="globalFill" style="width:0%;background:#06b6d4"></div></div><span class="dim-val" id="globalVal">0.00</span></div>
        </div>
        <div class="card"><div class="card-title">Tracked Skills</div><div id="skillList"></div></div>
        <div class="card"><div class="card-title">Forward-Model Prediction Errors</div><div id="predErrList"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.cerebellum;
  const g = s.globalCalibration || 0;
  document.getElementById('globalFill').style.width = Math.round(g*100) + '%';
  document.getElementById('globalVal').textContent = g.toFixed(2);

  const el = document.getElementById('skillList');
  if (s.skills && s.skills.length) {
    s.skills.forEach(sk => {
      el.innerHTML += `<div class="dim"><span class="dim-icon">🎯</span><span class="dim-name" style="max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${sk.name}">${sk.name}<span class="dim-sub">${sk.reps} reps · smooth ${sk.smoothness.toFixed(2)}</span></span><div class="dim-bar"><div class="dim-fill" style="width:${Math.round(sk.precision*100)}%;background:#06b6d4"></div></div><span class="dim-val">${sk.precision.toFixed(2)}</span></div>`;
    });
  } else {
    el.innerHTML = '<div class="empty">No skills tracked yet. Run log-execution.sh</div>';
  }
  const pe = document.getElementById('predErrList');
  if (s.skills && s.skills.length) {
    const withPE = s.skills.filter(sk => typeof sk.predictionError === 'number');
    if (withPE.length) {
      withPE.forEach(sk => {
        pe.innerHTML += `<div class="dim"><span class="dim-name">${sk.name}<span class="dim-sub">prediction error (EMA)</span></span><div class="dim-bar"><div class="dim-fill" style="width:${Math.min(100, Math.round(sk.predictionError*100))}%;background:#ec4899"></div></div><span class="dim-val">${sk.predictionError.toFixed(3)}</span></div>`;
      });
    } else {
      pe.innerHTML = '<div class="empty">No predictions made yet. Run log-execution.sh --predicted</div>';
    }
  } else {
    pe.innerHTML = '<div class="empty">No skills tracked yet.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson global "$GLOBAL" --argjson skills "$SKILLS" --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" '{installed: true, globalCalibration: $global, skills: $skills, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "cerebellum" --argjson order 95 --arg label "Precision" --arg icon "🎚️" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/cerebellum.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/dashboard-builder.sh" --focus cerebellum
