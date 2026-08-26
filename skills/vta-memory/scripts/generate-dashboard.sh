#!/bin/bash
# generate-dashboard.sh — Write VTA's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY VTA's own state file.
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/reward-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No VTA state found"; exit 1; }

DRIVE=$(jq -r '.drive // 0.5' "$STATE_FILE")
SEEKING=$(jq -c '.seeking // []' "$STATE_FILE")
ANTICIPATING=$(jq -c '.anticipating // []' "$STATE_FILE")
REWARDS=$(jq -c '[.recentRewards[-5:] // [] | .[] | {type, source, intensity}]' "$STATE_FILE")
RPE=$(jq -c '[.recentRPE[-5:] // [] | .[] | {type, rpe, expectedBefore, expectedAfter}]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="drive-meter"><div class="drive-val" id="driveVal">0%</div><div class="drive-label">Drive Level</div><div class="drive-bar"><div class="drive-fill" id="driveFill" style="width:0%"></div></div></div></div>
        <div class="card"><div class="card-title">Seeking</div><div id="vtaSeeking" class="tags"></div></div>
        <div class="card"><div class="card-title">Looking Forward To</div><div id="vtaAnticipating" class="tags"></div></div>
        <div class="card"><div class="card-title">Recent Rewards</div><div id="recentRewards"></div></div>
        <div class="card"><div class="card-title">Reward Prediction Errors (RPE)</div><div id="recentRPE"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.vta;
  const pct = Math.round((s.drive || 0) * 100);
  document.getElementById('driveVal').textContent = pct + '%';
  document.getElementById('driveFill').style.width = pct + '%';
  const sk = document.getElementById('vtaSeeking');
  (s.seeking || []).forEach(x => sk.innerHTML += `<span class="tag">${x}</span>`);
  if (!(s.seeking || []).length) sk.innerHTML = '<div class="empty">Nothing actively sought</div>';
  const an = document.getElementById('vtaAnticipating');
  (s.anticipating || []).forEach(x => an.innerHTML += `<span class="tag">${x}</span>`);
  if (!(s.anticipating || []).length) an.innerHTML = '<div class="empty">Nothing anticipated</div>';
  const rw = document.getElementById('recentRewards');
  if (s.recentRewards && s.recentRewards.length) {
    s.recentRewards.slice().reverse().forEach(r => {
      rw.innerHTML += `<div class="list-item"><div class="list-text">${r.type}</div><div class="list-sub">${r.source || '—'}</div></div>`;
    });
  } else {
    rw.innerHTML = '<div class="empty">No recent rewards</div>';
  }
  const rp = document.getElementById('recentRPE');
  if (s.recentRPE && s.recentRPE.length) {
    s.recentRPE.slice().reverse().forEach(e => {
      const cls = e.rpe >= 0 ? 'badge-chunked' : 'badge-critical';
      const sign = e.rpe >= 0 ? '+' : '';
      rp.innerHTML += `<div class="list-item"><div class="badge ${cls}">RPE ${sign}${e.rpe.toFixed(2)}</div><div class="list-text">${e.type}</div><div class="list-sub">expected ${e.expectedBefore.toFixed(2)} → ${e.expectedAfter.toFixed(2)}</div></div>`;
    });
  } else {
    rp.innerHTML = '<div class="empty">No prediction errors yet — rewards met expectation or none logged.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson drive "$DRIVE" --argjson seeking "$SEEKING" --argjson anticipating "$ANTICIPATING" --argjson recentRewards "$REWARDS" --argjson recentRPE "$RPE" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, drive: $drive, seeking: $seeking, anticipating: $anticipating, recentRewards: $recentRewards, recentRPE: $recentRPE, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "vta" --argjson order 30 --arg label "Drive" --arg icon "⭐" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/vta.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/dashboard-builder.sh" --focus vta
