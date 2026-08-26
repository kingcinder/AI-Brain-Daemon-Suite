#!/bin/bash
# generate-dashboard.sh — Write insula's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY insula's own state file.
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No insula state found"; exit 1; }

CHANNELS=$(jq -c '.channels // {}' "$STATE_FILE")
SIGNALS=$(jq -c '[.recentSignals // [] | .[-6:] | .[] | {channel: (.channel // "signal"), value: (.value // 0)}]' "$STATE_FILE")
DISC=$(jq -c '[.recentDiscrepancies // [] | .[-6:] | .[] | {channel, predicted, actual, error}]' "$STATE_FILE")
IPE=$(jq -r '.composite.interoceptiveDiscrepancy // 0' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="card-title">Interoceptive Channels</div><div id="insulaChannels"></div></div>
        <div class="card"><div class="card-title">Recent Signals</div><div id="recentSignals"></div></div>
        <div class="card"><div class="card-title">Interoceptive Prediction Errors</div><div id="insulaDisc"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.insula;
  const el = document.getElementById('insulaChannels');
  const ch = s.channels || {};
  Object.keys(ch).forEach(k => {
    const v = ch[k];
    el.innerHTML += `<div class="dim"><span class="dim-name">${k}</span><div class="dim-bar"><div class="dim-fill" style="width:${Math.round(v*100)}%"></div></div><span class="dim-val">${v.toFixed(2)}</span></div>`;
  });
  const rs = document.getElementById('recentSignals');
  if (s.recentSignals && s.recentSignals.length) {
    s.recentSignals.forEach(sig => {
      rs.innerHTML += `<div class="list-item"><div class="list-text">${sig.channel}</div><div class="list-sub">${sig.value.toFixed(2)}</div></div>`;
    });
  } else {
    rs.innerHTML = '<div class="empty">No recent signals.</div>';
  }
  const disc = document.getElementById('insulaDisc');
  const ipe = s.interoceptiveDiscrepancy || 0;
  if (s.recentDiscrepancies && s.recentDiscrepancies.length) {
    disc.innerHTML = `<div class="dim"><span class="dim-name">Composite error<span class="dim-sub">|actual − predicted| mean</span></span><div class="dim-bar"><div class="dim-fill" style="width:${Math.min(100, Math.round(ipe*100))}%;background:#14b8a6"></div></div><span class="dim-val">${ipe.toFixed(3)}</span></div>`;
    s.recentDiscrepancies.slice().reverse().forEach(d => {
      disc.innerHTML += `<div class="list-item"><div class="list-text">${d.channel}</div><div class="list-sub">pred ${d.predicted.toFixed(2)} → actual ${d.actual.toFixed(2)} · err ${d.error.toFixed(3)}</div></div>`;
    });
  } else {
    disc.innerHTML = '<div class="empty">No interoceptive discrepancies — sensed state matches prediction.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson channels "$CHANNELS" --argjson recentSignals "$SIGNALS" --argjson recentDiscrepancies "$DISC" --argjson interoceptiveDiscrepancy "$IPE" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, channels: $channels, recentSignals: $recentSignals, recentDiscrepancies: $recentDiscrepancies, interoceptiveDiscrepancy: $interoceptiveDiscrepancy, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "insula" --argjson order 70 --arg label "Sense" --arg icon "🌡️" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/insula.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/dashboard-builder.sh" --focus insula
