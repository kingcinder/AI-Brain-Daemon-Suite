#!/bin/bash
# generate-dashboard.sh — Write anterior-cingulate-memory's own dashboard
# fragment, then call the shared dashboard-builder.sh. Reads ONLY the
# conflict organ's own state (memory/conflict-state.json).
#
# Replaced 2026-11-25: the previous script was a pre-fragment monolith
# that rewrote the whole brain-dashboard.html (7-module era) and wrote no
# fragment, so the builder's Conflicts tab (registry id acc_conflict)
# rendered empty — conflicts were processing but never reporting to the
# dashboard.
# Backup: ~/workspace/memory-backups/acc-conflict-generate-dashboard-monolith-2026-11-25.sh
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"
mkdir -p "$FRAGMENTS_DIR"

LOAD=0; ACTIVE_COUNT=0; FLAGS_COUNT=0; ZONES_COUNT=0
ENCODE_RUNS=0; TOTAL_LOGGED=0; RESOLVED=0
LAST_UPDATED="never"; LAST_CONSULTED="never"
CONFLICTS_JSON="[]"; FLAGS_JSON="[]"

if [ -f "$STATE_FILE" ]; then
    LOAD=$(jq -r '.conflictLoad // 0' "$STATE_FILE")
    ACTIVE_COUNT=$(jq -r '.activeConflicts | length' "$STATE_FILE")
    FLAGS_COUNT=$(jq -r '.attentionFlags | length' "$STATE_FILE")
    ZONES_COUNT=$(jq -r '.uncertaintyZones | length' "$STATE_FILE")
    ENCODE_RUNS=$(jq -r '.stats.encodingRuns // 0' "$STATE_FILE")
    TOTAL_LOGGED=$(jq -r '.stats.totalConflictsLogged // 0' "$STATE_FILE")
    RESOLVED=$(jq -r '.stats.totalResolved // 0' "$STATE_FILE")
    LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE")
    LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
    CONFLICTS_JSON=$(jq -c '[(.activeConflicts | if type == "array" then . else to_entries | map(.value) end)[] | {type: (.type // "unknown"), severity: (.severity // "low"), description: (.description // "")}] | .[:10]' "$STATE_FILE")
    FLAGS_JSON=$(jq -c '[.attentionFlags[] | {topic: (.topic // ""), reason: (.reason // "")}] | .[:10]' "$STATE_FILE")
fi

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="dim"><span class="dim-icon">⚡</span><span class="dim-name">Conflict load</span><div class="dim-bar"><div class="dim-fill" id="acLoadFill" style="width:0%;background:#f59e0b"></div></div><span class="dim-val" id="acLoadVal">0.00</span></div>
            <div class="dim"><span class="dim-icon">🎚️</span><span class="dim-name">Status</span><span class="dim-val" id="acStatus">—</span></div>
        </div>
        <div class="card"><div class="card-title">Conflicts (ACC)</div><div class="stats-4">
            <div class="stat"><div class="stat-val-sm" id="acActive">0</div><div class="stat-label">Active</div></div>
            <div class="stat"><div class="stat-val-sm" id="acFlags">0</div><div class="stat-label">Attention Flags</div></div>
            <div class="stat"><div class="stat-val-sm" id="acZones">0</div><div class="stat-label">Uncertainty Zones</div></div>
            <div class="stat"><div class="stat-val-sm" id="acRuns">0</div><div class="stat-label">Encode Runs</div></div>
        </div></div>
        <div class="card"><div class="card-title">Active Conflicts</div><div id="acConflicts"></div></div>
        <div class="card"><div class="card-title">Attention Flags</div><div id="acFlagList"></div></div>
        <div class="card">
            <div class="dim"><span class="dim-icon">🕐</span><span class="dim-name">Last consulted</span><span class="dim-val" id="acConsulted">never</span></div>
        </div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.acc_conflict || {};
  const set = (id, v) => { const e = document.getElementById(id); if (e) e.textContent = v; };
  const load = s.conflictLoad || 0;
  const fill = document.getElementById('acLoadFill');
  if (fill) {
    fill.style.width = Math.round(load * 100) + '%';
    fill.style.background = load < 0.2 ? '#22c55e' : load < 0.4 ? '#eab308' : load < 0.6 ? '#f59e0b' : load < 0.8 ? '#ef4444' : '#dc2626';
  }
  set('acLoadVal', load.toFixed(2));
  set('acStatus', load < 0.2 ? '🟢 Clear' : load < 0.4 ? '🟡 Low' : load < 0.6 ? '🟠 Moderate' : load < 0.8 ? '🔴 Elevated' : '🚨 Critical');
  set('acActive', s.activeCount || 0);
  set('acFlags', s.flagsCount || 0);
  set('acZones', s.zonesCount || 0);
  set('acRuns', s.encodingRuns || 0);
  set('acConsulted', s.lastConsultedAt || 'never');
  const list = document.getElementById('acConflicts');
  if (list) {
    if (s.conflicts && s.conflicts.length) {
      s.conflicts.forEach(c => {
        const row = document.createElement('div'); row.className = 'li';
        const badge = document.createElement('span');
        badge.className = 'badge ' + (c.severity === 'high' ? 'br' : c.severity === 'moderate' ? 'ba' : 'bf');
        badge.textContent = c.type;
        const desc = document.createElement('span'); desc.className = 'lt';
        desc.textContent = c.description;
        row.appendChild(badge); row.appendChild(desc);
        list.appendChild(row);
      });
    } else {
      list.innerHTML = '<div class="empty">No active conflicts</div>';
    }
  }
  const fl = document.getElementById('acFlagList');
  if (fl) {
    if (s.flags && s.flags.length) {
      s.flags.forEach(f => {
        const row = document.createElement('div'); row.className = 'li';
        const body = document.createElement('div');
        const topic = document.createElement('span'); topic.className = 'lt';
        topic.textContent = '📌 ' + f.topic;
        const reason = document.createElement('div'); reason.className = 'steps';
        reason.textContent = f.reason;
        body.appendChild(topic); body.appendChild(reason);
        row.appendChild(body);
        fl.appendChild(row);
      });
    } else {
      fl.innerHTML = '<div class="empty">No attention flags</div>';
    }
  }
})();
SCRIPTEOF
)

DATA_JSON=$(jq -n --argjson conflictLoad "$LOAD" --argjson activeCount "$ACTIVE_COUNT" \
    --argjson flagsCount "$FLAGS_COUNT" --argjson zonesCount "$ZONES_COUNT" \
    --argjson encodingRuns "$ENCODE_RUNS" --argjson totalLogged "$TOTAL_LOGGED" \
    --argjson totalResolved "$RESOLVED" \
    --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
    --argjson conflicts "$CONFLICTS_JSON" --argjson flags "$FLAGS_JSON" \
    '{installed: true, conflictLoad: $conflictLoad, activeCount: $activeCount, flagsCount: $flagsCount, zonesCount: $zonesCount, encodingRuns: $encodingRuns, totalLogged: $totalLogged, totalResolved: $totalResolved, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt, conflicts: $conflicts, flags: $flags}' \
    2>/dev/null) || DATA_JSON='{"installed": true}'

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "acc_conflict" --argjson order 60 --arg label "Conflicts" --arg icon "⚡" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/acc_conflict.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/dashboard-builder.sh" --focus acc_conflict
