#!/bin/bash
# generate-dashboard.sh — Write executive-function's own dashboard fragment,
# then call the shared dashboard-builder.sh. Reads ONLY executive-function's
# own state files (executive-load.json, last-cycle.json, goal-proposals.jsonl).
# The fragment is ALWAYS written (even with no state yet) so the tab appears
# in the dashboard; the JS renders a "no data yet" state instead.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
LOAD_FILE="$WORKSPACE/memory/executive-load.json"
CYCLE_FILE="$WORKSPACE/memory/executive/last-cycle.json"
PROPOSALS_FILE="$WORKSPACE/memory/executive/goal-proposals.jsonl"
OUTCOMES_FILE="$WORKSPACE/memory/executive/goal-outcomes.jsonl"
mkdir -p "$FRAGMENTS_DIR"

# ── Defaults (fragment always written; JS shows placeholder if no state) ──
E="0.0"; BAND="—"; G="0"; Q="0"; REDUCE=false
LAST_CYCLE="never"; PHASE="—"
PROPOSAL_COUNT=0; PROPOSAL_LATEST=""
SUCCESS_COUNT=0; FAIL_COUNT=0

if [ -f "$LOAD_FILE" ]; then
    E=$(jq -r '.E // 0' "$LOAD_FILE")
    BAND=$(jq -r '.band // "—"' "$LOAD_FILE")
    G=$(jq -r '.G // 0' "$LOAD_FILE")
    Q=$(jq -r '.Q // 0' "$LOAD_FILE")
    REDUCE=$(jq -r '.load_reduction_recommended // false' "$LOAD_FILE")
fi
if [ -f "$CYCLE_FILE" ]; then
    LAST_CYCLE=$(jq -r '.last_cycle_utc // "never"' "$CYCLE_FILE")
    PHASE=$(jq -r '.phase // "—"' "$CYCLE_FILE")
fi
if [ -f "$PROPOSALS_FILE" ]; then
    PROPOSAL_COUNT=$(wc -l < "$PROPOSALS_FILE")
    PROPOSAL_LATEST=$(tail -1 "$PROPOSALS_FILE" 2>/dev/null | jq -r '.description // ""' 2>/dev/null || true)
fi
if [ -f "$OUTCOMES_FILE" ]; then
    # jq (not grep) — JSON-safe regardless of field spacing/order.
    SUCCESS_COUNT=$(jq -c 'select(.outcome == "success")' "$OUTCOMES_FILE" 2>/dev/null | wc -l)
    FAIL_COUNT=$(jq -c 'select(.outcome == "failure")' "$OUTCOMES_FILE" 2>/dev/null | wc -l)
fi

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="dim"><span class="dim-icon">⚖️</span><span class="dim-name">Executive Load</span><div class="dim-bar"><div class="dim-fill" id="execLoadFill" style="width:0%;background:linear-gradient(90deg,#10b981,#f59e0b)"></div></div><span class="dim-val" id="execLoadVal">0.00</span></div>
            <div class="dim"><span class="dim-icon">🎯</span><span class="dim-name">Band</span><span class="dim-val" id="execBand">—</span></div>
            <div class="dim"><span class="dim-icon">🗂️</span><span class="dim-name">Active Goals / Queue</span><span class="dim-val" id="execGoals">0 / 0</span></div>
        </div>
        <div class="card"><div class="card-title">Recent Goal Proposals</div><div id="execProposals"></div></div>
        <div class="card"><div class="card-title">Outcomes</div><div class="stats-3">
            <div class="stat"><div class="stat-val-sm" id="execOk">0</div><div class="stat-label">Success</div></div>
            <div class="stat"><div class="stat-val-sm" id="execFail">0</div><div class="stat-label">Failure</div></div>
            <div class="stat"><div class="stat-val-sm" id="execCycle">—</div><div class="stat-label">Last Cycle</div></div>
        </div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.executive || {};
  const load = s.E || 0;
  const fill = document.getElementById('execLoadFill');
  const val = document.getElementById('execLoadVal');
  if (fill) fill.style.width = Math.min(100, Math.round(load * 100)) + '%';
  if (val) val.textContent = load.toFixed(2);
  const band = document.getElementById('execBand');
  if (band) band.textContent = s.band || '—';
  if (s.loadReduction) { const b = document.getElementById('execBand'); if (b) b.style.color = '#f59e0b'; }
  const g = document.getElementById('execGoals');
  if (g) g.textContent = (s.G || 0) + ' / ' + (s.Q || 0);
  const pl = document.getElementById('execProposals');
  if (pl) {
    if (s.latestProposal) {
      pl.innerHTML = '<div class="list-item"><div class="list-text">' + s.latestProposal + '<div class="list-sub">' + (s.proposalCount || 0) + ' proposals on file</div></div></div>';
    } else {
      pl.innerHTML = '<div class="empty">No goal proposals yet. Run the executive cycle.</div>';
    }
  }
  const ok = document.getElementById('execOk');
  if (ok) ok.textContent = s.successCount || 0;
  const fl = document.getElementById('execFail');
  if (fl) fl.textContent = s.failCount || 0;
  const cyc = document.getElementById('execCycle');
  if (cyc) cyc.textContent = (s.lastCycle || '—').slice(0, 10);
})();
SCRIPTEOF
)

# Guarded: a malformed (non-numeric) field in a present state file must never
# abort the always-write guarantee — fall back to a minimal fragment so the
# tab still appears (JS renders defaults).
DATA_JSON=$(jq -n --argjson E "$E" --arg band "$BAND" --argjson G "$G" --argjson Q "$Q" \
    --argjson loadReduction "$REDUCE" --arg lastCycle "$LAST_CYCLE" --arg phase "$PHASE" \
    --argjson proposalCount "$PROPOSAL_COUNT" --arg latestProposal "$PROPOSAL_LATEST" \
    --argjson successCount "$SUCCESS_COUNT" --argjson failCount "$FAIL_COUNT" \
    '{installed: true, E: $E, band: $band, G: $G, Q: $Q, loadReduction: $loadReduction, lastCycle: $lastCycle, phase: $phase, proposalCount: $proposalCount, latestProposal: $latestProposal, successCount: $successCount, failCount: $failCount}' \
    2>/dev/null) || DATA_JSON='{"installed": true}'

echo "$HTML" > /tmp/exec_frag_html.$$
echo "$SCRIPT" > /tmp/exec_frag_script.$$
jq -n --arg id "executive" --argjson order 12 --arg label "Governance" --arg icon "🎛️" \
  --rawfile html /tmp/exec_frag_html.$$ --rawfile script /tmp/exec_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/executive.json"
rm -f /tmp/exec_frag_html.$$ /tmp/exec_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus executive
