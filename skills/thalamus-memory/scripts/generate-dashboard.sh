#!/bin/bash
# generate-dashboard.sh — Write thalamus-memory's own dashboard fragment,
# then call the shared dashboard-builder.sh. Reads ONLY thalamus's own state
# (memory/thalamus-state.json). The fragment is ALWAYS written (even with no
# state yet) so the 🚦 tab appears; the JS renders a "gate not yet run" state.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"
mkdir -p "$FRAGMENTS_DIR"

# ── Defaults (fragment always written; JS shows placeholder if no state) ──
TOTAL=0; AMPLIFIED=0; PASSED=0; ATTENUATED=0; SUPPRESSED=0; DISPATCHED=0
PENDING=0; SENSITIVITY=0.5; LAST_GATE="never"
FOCUS_JSON="[]"

if [ -f "$STATE_FILE" ]; then
    TOTAL=$(jq -r '.stats.totalSignalsProcessed // 0' "$STATE_FILE")
    AMPLIFIED=$(jq -r '.stats.amplified // 0' "$STATE_FILE")
    PASSED=$(jq -r '.stats.passed // 0' "$STATE_FILE")
    ATTENUATED=$(jq -r '.stats.attenuated // 0' "$STATE_FILE")
    SUPPRESSED=$(jq -r '.stats.suppressed // 0' "$STATE_FILE")
    DISPATCHED=$(jq -r '.stats.dispatchedToTargets // 0' "$STATE_FILE")
    PENDING=$(jq -r '.suppressedQueue | length // 0' "$STATE_FILE")
    SENSITIVITY=$(jq -r '.gateSensitivity // 0.5' "$STATE_FILE")
    LAST_GATE=$(jq -r '.lastGateRun // "never"' "$STATE_FILE")
    FOCUS_JSON=$(jq -c '.attentionFocus // []' "$STATE_FILE")
fi

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="card-title">Signals Through the Gate</div><div class="stats-4">
            <div class="stat"><div class="stat-val-sm" id="thTotal">0</div><div class="stat-label">Processed</div></div>
            <div class="stat"><div class="stat-val-sm" id="thAmp">0</div><div class="stat-label">Amplified</div></div>
            <div class="stat"><div class="stat-val-sm" id="thSupp">0</div><div class="stat-label">Suppressed</div></div>
            <div class="stat"><div class="stat-val-sm" id="thDisp">0</div><div class="stat-label">Dispatched</div></div>
        </div></div>
        <div class="card">
            <div class="dim"><span class="dim-icon">🎚️</span><span class="dim-name">Gate sensitivity</span><div class="dim-bar"><div class="dim-fill" id="thSenseFill" style="width:0%;background:linear-gradient(90deg,#06b6d4,#a855f7)"></div></div><span class="dim-val" id="thSenseVal">0.50</span></div>
            <div class="dim"><span class="dim-icon">📋</span><span class="dim-name">Pending (suppressed queue)</span><span class="dim-val" id="thPending">0</span></div>
        </div>
        <div class="card"><div class="card-title">Attention Focus</div><div id="thFocus" class="tags"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.thalamus || {};
  const t = document.getElementById('thTotal'); if (t) t.textContent = s.total || 0;
  const a = document.getElementById('thAmp'); if (a) a.textContent = s.amplified || 0;
  const su = document.getElementById('thSupp'); if (su) su.textContent = s.suppressed || 0;
  const d = document.getElementById('thDisp'); if (d) d.textContent = s.dispatched || 0;
  const sens = s.sensitivity || 0.5;
  const fill = document.getElementById('thSenseFill');
  const val = document.getElementById('thSenseVal');
  if (fill) fill.style.width = Math.round(sens * 100) + '%';
  if (val) val.textContent = sens.toFixed(2);
  const p = document.getElementById('thPending'); if (p) p.textContent = s.pending || 0;
  const f = document.getElementById('thFocus');
  if (f) {
    if (s.focus && s.focus.length) {
      f.innerHTML = s.focus.map(x => '<span class="tag">' + x + '</span>').join('');
    } else {
      f.innerHTML = '<div class="empty">No attention focus set — gate not run yet.</div>';
    }
  }
})();
SCRIPTEOF
)

# Guarded: a malformed (non-numeric) field in a present state file must never
# abort the always-write guarantee — fall back to a minimal fragment.
DATA_JSON=$(jq -n --argjson total "$TOTAL" --argjson amplified "$AMPLIFIED" --argjson passed "$PASSED" \
    --argjson attenuated "$ATTENUATED" --argjson suppressed "$SUPPRESSED" --argjson dispatched "$DISPATCHED" \
    --argjson pending "$PENDING" --argjson sensitivity "$SENSITIVITY" --arg lastGate "$LAST_GATE" \
    --argjson focus "$FOCUS_JSON" \
    '{installed: true, total: $total, amplified: $amplified, passed: $passed, attenuated: $attenuated, suppressed: $suppressed, dispatched: $dispatched, pending: $pending, sensitivity: $sensitivity, lastGate: $lastGate, focus: $focus}' \
    2>/dev/null) || DATA_JSON='{"installed": true}'

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "thalamus" --argjson order 80 --arg label "Thalamus" --arg icon "🚦" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/thalamus.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/dashboard-builder.sh" --focus thalamus
