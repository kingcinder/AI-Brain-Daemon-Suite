#!/bin/bash
# generate-dashboard.sh — Write acc-error-memory's own dashboard fragment,
# then call the shared dashboard-builder.sh. Reads ONLY acc-error's own
# state (memory/acc-state.json).
#
# Replaced 2026-11-25: the previous script was a pre-fragment monolith
# that rewrote the whole brain-dashboard.html (7-module era) and wrote no
# fragment, so the builder's Errors tab (registry id acc_error) rendered
# empty — errors were processing but never reporting to the dashboard.
# Backup: ~/workspace/memory-backups/acc-error-generate-dashboard-monolith-2026-11-25.sh
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/acc-state.json"
mkdir -p "$FRAGMENTS_DIR"

TOTAL_LOGGED=0; TOTAL_SCREENED=0; TOTAL_ANALYZED=0; TOTAL_RESOLVED=0
TOTAL_REGRESSIONS=0; ACTIVE_COUNT=0; CRITICAL_COUNT=0; WARNING_COUNT=0
LAST_UPDATED="never"; LAST_CONSULTED="never"; PATTERNS_JSON="[]"

if [ -f "$STATE_FILE" ]; then
    TOTAL_LOGGED=$(jq -r '.stats.totalErrorsLogged // 0' "$STATE_FILE")
    TOTAL_SCREENED=$(jq -r '.stats.totalScreened // 0' "$STATE_FILE")
    TOTAL_ANALYZED=$(jq -r '.stats.totalAnalyzed // 0' "$STATE_FILE")
    TOTAL_RESOLVED=$(jq -r '.stats.totalResolved // 0' "$STATE_FILE")
    TOTAL_REGRESSIONS=$(jq -r '.stats.totalRegressions // 0' "$STATE_FILE")
    ACTIVE_COUNT=$(jq -r '.activePatterns | length' "$STATE_FILE")
    CRITICAL_COUNT=$(jq -r '[.activePatterns[] | select(.severity == "critical")] | length' "$STATE_FILE")
    WARNING_COUNT=$(jq -r '[.activePatterns[] | select(.severity == "warning")] | length' "$STATE_FILE")
    LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE")
    LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
    PATTERNS_JSON=$(jq -c '[.activePatterns | to_entries[] | {pattern: .key, count: (.value.count // 0), severity: (.value.severity // "normal"), lastSeen: (.value.lastSeen // ""), mitigation: (.value.mitigation // "")}] | sort_by(-.count) | .[:10]' "$STATE_FILE")
fi

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="card-title">Error Patterns (ACC)</div><div class="stats-4">
            <div class="stat"><div class="stat-val-sm" id="aeLogged">0</div><div class="stat-label">Logged</div></div>
            <div class="stat"><div class="stat-val-sm" id="aeActive">0</div><div class="stat-label">Active Patterns</div></div>
            <div class="stat"><div class="stat-val-sm" id="aeCritical">0</div><div class="stat-label">Critical</div></div>
            <div class="stat"><div class="stat-val-sm" id="aeResolved">0</div><div class="stat-label">Resolved</div></div>
        </div></div>
        <div class="card"><div class="card-title">Top Error Patterns</div><div id="aePatterns"></div></div>
        <div class="card">
            <div class="dim"><span class="dim-icon">🔍</span><span class="dim-name">Screened / analyzed</span><span class="dim-val" id="aeScreened">0 / 0</span></div>
            <div class="dim"><span class="dim-icon">↩️</span><span class="dim-name">Regressions</span><span class="dim-val" id="aeRegressions">0</span></div>
            <div class="dim"><span class="dim-icon">🕐</span><span class="dim-name">Last consulted</span><span class="dim-val" id="aeConsulted">never</span></div>
        </div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.acc_error || {};
  const set = (id, v) => { const e = document.getElementById(id); if (e) e.textContent = v; };
  set('aeLogged', s.totalLogged || 0);
  set('aeActive', s.activeCount || 0);
  set('aeCritical', s.criticalCount || 0);
  set('aeResolved', s.totalResolved || 0);
  set('aeScreened', (s.totalScreened || 0) + ' / ' + (s.totalAnalyzed || 0));
  set('aeRegressions', s.totalRegressions || 0);
  set('aeConsulted', s.lastConsultedAt || 'never');
  const el = document.getElementById('aePatterns');
  if (el) {
    if (s.patterns && s.patterns.length) {
      s.patterns.forEach(p => {
        const row = document.createElement('div'); row.className = 'li';
        const badge = document.createElement('span');
        badge.className = 'badge ' + (p.severity === 'critical' ? 'br' : p.severity === 'warning' ? 'ba' : 'bf');
        badge.textContent = p.severity;
        const body = document.createElement('div');
        const name = document.createElement('span'); name.className = 'lt';
        name.textContent = p.pattern + ' (' + (p.count || 0) + 'x)';
        const mit = document.createElement('div'); mit.className = 'steps';
        mit.textContent = p.mitigation || 'No mitigation set';
        body.appendChild(name); body.appendChild(mit);
        row.appendChild(badge); row.appendChild(body);
        el.appendChild(row);
      });
    } else {
      el.innerHTML = '<div class="empty">No active error patterns</div>';
    }
  }
})();
SCRIPTEOF
)

DATA_JSON=$(jq -n --argjson totalLogged "$TOTAL_LOGGED" --argjson totalScreened "$TOTAL_SCREENED" \
    --argjson totalAnalyzed "$TOTAL_ANALYZED" --argjson totalResolved "$TOTAL_RESOLVED" \
    --argjson totalRegressions "$TOTAL_REGRESSIONS" --argjson activeCount "$ACTIVE_COUNT" \
    --argjson criticalCount "$CRITICAL_COUNT" --argjson warningCount "$WARNING_COUNT" \
    --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
    --argjson patterns "$PATTERNS_JSON" \
    '{installed: true, totalLogged: $totalLogged, totalScreened: $totalScreened, totalAnalyzed: $totalAnalyzed, totalResolved: $totalResolved, totalRegressions: $totalRegressions, activeCount: $activeCount, criticalCount: $criticalCount, warningCount: $warningCount, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt, patterns: $patterns}' \
    2>/dev/null) || DATA_JSON='{"installed": true}'

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "acc_error" --argjson order 50 --arg label "Errors" --arg icon "🔴" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/acc_error.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/dashboard-builder.sh" --focus acc_error
