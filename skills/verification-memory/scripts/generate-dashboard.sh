#!/bin/bash
# generate-dashboard.sh — Write verification-memory's own dashboard fragment,
# then call the shared dashboard-builder.sh. Reads ONLY its own state file.
set -u

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/verification-state.json"
mkdir -p "$FRAGMENTS_DIR"

[ ! -f "$STATE_FILE" ] && { echo "No verification state found"; exit 1; }

LAST_RUN=$(jq -r '.lastRun // "never"' "$STATE_FILE")
TOTAL=$(jq -r '.totals.tests // 0' "$STATE_FILE")
PASSED=$(jq -r '.totals.passed // 0' "$STATE_FILE")
FAILED=$(jq -r '.totals.failed // 0' "$STATE_FILE")
FAILURES=$(jq -c '[.lastFailure[]?]' "$STATE_FILE" 2>/dev/null || echo "[]")

HTML=$(cat << 'HTMLEOF'
        <style>
          .spark-row { display: flex; align-items: flex-end; gap: 3px; height: 26px; padding: 4px 0; }
          .spark-bar { flex: 1; min-width: 3px; border-radius: 2px 2px 0 0; background: var(--accent); transition: background 0.2s; }
          .spark-bar.green { background: var(--emerald); }
          .spark-bar.amber { background: var(--amber); }
          .spark-bar.red { background: #ef4444; }
          .health-summary { font-size: 0.78rem; color: var(--text-secondary); display: grid; gap: 4px; margin-top: 8px; }
          .health-best { color: var(--emerald); font-weight: 600; }
          .health-worst { color: #f87171; font-weight: 600; }
          .region-row { display: flex; align-items: center; gap: 8px; padding: 8px 0; border-bottom: 1px solid var(--border); }
          .region-row:last-child { border: none; }
          .region-name { flex: 1; font-size: 0.78rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .region-rate { width: 46px; text-align: right; font-size: 0.75rem; color: var(--text-secondary); font-variant-numeric: tabular-nums; }
        </style>
        <div class="card"><div class="stats-3">
          <div class="stat"><div class="stat-val" id="vTotal">0</div><div class="stat-label">Declared Tests</div></div>
          <div class="stat"><div class="stat-val" id="vPassed">0</div><div class="stat-label">Passed</div></div>
          <div class="stat"><div class="stat-val" id="vFailed">0</div><div class="stat-label">Failed</div></div>
        </div></div>
        <div class="card"><div class="card-title">Failures</div><div id="vFailureList"></div></div>
        <div class="card"><div class="card-title">Long-Term Health · Pass Rate Trend</div>
          <div class="spark-row" id="vTrend"></div>
          <div class="health-summary" id="vHealthSummary"></div>
        </div>
        <div class="card"><div class="card-title">Region Health</div><div id="vRegionRows"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.verification;
  document.getElementById('vTotal').textContent = s.total;
  document.getElementById('vPassed').textContent = s.passed;
  const failedEl = document.getElementById('vFailed');
  failedEl.textContent = s.failed;
  if (s.failed > 0) failedEl.style.color = '#f87171';
  const el = document.getElementById('vFailureList');
  if (s.failures && s.failures.length) {
    s.failures.forEach(f => {
      el.innerHTML += `<div class="list-item"><div class="list-text">${f}</div></div>`;
    });
  } else {
    el.innerHTML = '<div class="empty">All declared tests green ✨</div>';
  }

  // Long-term health: overall pass-rate sparkline (last N runs)
  const bar = (rate) => {
    const b = document.createElement('div');
    b.className = 'spark-bar ' + (rate >= 0.9 ? 'green' : rate >= 0.7 ? 'amber' : 'red');
    b.style.height = (4 + Math.round((rate || 0) * 18)) + 'px';
    return b;
  };
  const trend = document.getElementById('vTrend');
  if (s.history && s.history.length) {
    s.history.forEach(h => {
      const b = bar(h.pass_rate);
      b.title = `${h.ts} · ${h.passed}/${h.tests} passed (${Math.round((h.pass_rate || 0) * 100)}%)`;
      trend.appendChild(b);
    });
  } else {
    trend.innerHTML = '<div class="empty" style="width:100%">No history yet — run a few sweeps.</div>';
  }

  const hs = document.getElementById('vHealthSummary');
  if (s.healthiest && s.unhealthiest) {
    hs.innerHTML =
      `<div>🏆 Healthiest: <span class="health-best">${s.healthiest.module}</span> · ${Math.round(s.healthiest.pass_rate * 100)}% (${s.healthiest.runs} run${s.healthiest.runs === 1 ? '' : 's'})</div>` +
      `<div>🚨 Unhealthiest: <span class="health-worst">${s.unhealthiest.module}</span> · ${Math.round(s.unhealthiest.pass_rate * 100)}% (${s.unhealthiest.runs} run${s.unhealthiest.runs === 1 ? '' : 's'})</div>`;
  } else {
    hs.innerHTML = '<div class="empty">Collect more runs to rank regions.</div>';
  }

  const rows = document.getElementById('vRegionRows');
  if (s.modules && s.modules.length) {
    s.modules.forEach(m => {
      const row = document.createElement('div');
      row.className = 'region-row';
      const spark = (m.history || []).map(h => {
        const b = bar(h.pass_rate);
        b.style.flex = '0 0 3px';
        b.style.height = (4 + Math.round((h.pass_rate || 0) * 14)) + 'px';
        return b.outerHTML;
      }).join('');
      const rate = Math.round(m.pass_rate * 100);
      row.innerHTML = `<span class="region-name" title="${m.module}: ${rate}% over ${m.runs} run${m.runs === 1 ? '' : 's'}">${m.module}</span><div class="spark-row" style="flex:0 0 auto;gap:2px;height:18px">${spark}</div><span class="region-rate">${rate}%</span>`;
      rows.appendChild(row);
    });
  } else {
    rows.innerHTML = '<div class="empty">No per-module history yet.</div>';
  }
})();
SCRIPTEOF
)

HISTORY_JSON=$("$SCRIPT_DIR/query-history.sh" --limit 12 2>/dev/null || echo '{}')

DATA_JSON=$(jq -n --argjson total "$TOTAL" --argjson passed "$PASSED" --argjson failed "$FAILED" \
  --argjson failures "$FAILURES" --arg lastRun "$LAST_RUN" \
  --argjson history "$(echo "$HISTORY_JSON" | jq -c '.history // []' 2>/dev/null)" \
  --argjson modules "$(echo "$HISTORY_JSON" | jq -c '.modules // []' 2>/dev/null)" \
  --argjson healthiest "$(echo "$HISTORY_JSON" | jq -c '.healthiest // null' 2>/dev/null)" \
  --argjson unhealthiest "$(echo "$HISTORY_JSON" | jq -c '.unhealthiest // null' 2>/dev/null)" \
  '{installed: true, total: $total, passed: $passed, failed: $failed, failures: $failures, lastRun: $lastRun, history: $history, modules: $modules, healthiest: $healthiest, unhealthiest: $unhealthiest}')

echo "$HTML" > /tmp/vm_frag_html.$$
echo "$SCRIPT" > /tmp/vm_frag_script.$$
jq -n --arg id "verification" --argjson order 96 --arg label "Verification" --arg icon "🩺" \
  --rawfile html /tmp/vm_frag_html.$$ --rawfile script /tmp/vm_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/verification.json"
rm -f /tmp/vm_frag_html.$$ /tmp/vm_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus verification 2>/dev/null || true
