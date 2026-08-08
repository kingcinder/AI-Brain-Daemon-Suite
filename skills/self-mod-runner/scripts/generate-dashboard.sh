#!/bin/bash
# generate-dashboard.sh — Write self-mod-runner's own dashboard fragment,
# then call the shared dashboard-builder.sh. Reads ONLY self-mod-runner's own
# state (live-metrics.json, graduation-streak.json + dir counts). The fragment
# is ALWAYS written (even with no state yet) so the tab appears; the JS renders
# a "no data yet" state instead.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
SELF_MOD_DIR="$WORKSPACE/memory/self-mod"
LIVE_FILE="$SELF_MOD_DIR/live-metrics.json"
STREAK_FILE="$SELF_MOD_DIR/graduation-streak.json"
mkdir -p "$FRAGMENTS_DIR"

# ── Defaults (fragment always written; JS shows placeholder if no state) ──
TASK_SUCCESS="0.0"; LATENCY="0.0"; KV="0.0"
STREAK=0; STREAK_TARGET=20; LAST_EVENT="—"; REVIEW_MODE="—"; LAST_UPDATED="never"
PROPOSALS=0; DEPLOYS=0; RUNS=0

if [ -f "$LIVE_FILE" ]; then
    TASK_SUCCESS=$(jq -r '.task_success // 0' "$LIVE_FILE")
    LATENCY=$(jq -r '.latency_norm // 0' "$LIVE_FILE")
    KV=$(jq -r '.memory_kv_norm // 0' "$LIVE_FILE")
fi
if [ -f "$STREAK_FILE" ]; then
    STREAK=$(jq -r '.clean_streak // 0' "$STREAK_FILE")
    STREAK_TARGET=$(jq -r '.clean_streak_target // 20' "$STREAK_FILE")
    LAST_EVENT=$(jq -r '.last_event // "—"' "$STREAK_FILE")
    REVIEW_MODE=$(jq -r '.review_mode // "—"' "$STREAK_FILE")
    LAST_UPDATED=$(jq -r '.last_updated // "never"' "$STREAK_FILE")
fi
[ -d "$SELF_MOD_DIR/proposals" ] && PROPOSALS=$(ls "$SELF_MOD_DIR/proposals" 2>/dev/null | wc -l)
[ -d "$SELF_MOD_DIR/deploys" ] && DEPLOYS=$(ls "$SELF_MOD_DIR/deploys" 2>/dev/null | wc -l)
[ -d "$SELF_MOD_DIR/pipeline-runs" ] && RUNS=$(ls "$SELF_MOD_DIR/pipeline-runs" 2>/dev/null | wc -l)

HTML=$(cat << 'HTMLEOF'
        <div class="card">
            <div class="card-title">Graduation Streak</div>
            <div class="dim"><span class="dim-icon">🏆</span><span class="dim-name">Clean streak</span><div class="dim-bar"><div class="dim-fill" id="smStreakFill" style="width:0%;background:linear-gradient(90deg,#10b981,#a855f7)"></div></div><span class="dim-val" id="smStreakVal">0 / 20</span></div>
            <div class="dim"><span class="dim-icon">🛡️</span><span class="dim-name">Review mode</span><span class="dim-val" id="smReview">—</span></div>
        </div>
        <div class="card"><div class="card-title">Live Metrics</div>
            <div class="dim"><span class="dim-icon">✅</span><span class="dim-name">Task success</span><span class="dim-val" id="smTask">0.00</span></div>
            <div class="dim"><span class="dim-icon">⏱️</span><span class="dim-name">Latency (norm)</span><span class="dim-val" id="smLatency">0.00</span></div>
            <div class="dim"><span class="dim-icon">🧠</span><span class="dim-name">KV headroom (norm)</span><span class="dim-val" id="smKv">0.00</span></div>
        </div>
        <div class="card"><div class="card-title">Pipeline Activity</div><div class="stats-3">
            <div class="stat"><div class="stat-val-sm" id="smProposals">0</div><div class="stat-label">Proposals</div></div>
            <div class="stat"><div class="stat-val-sm" id="smDeploys">0</div><div class="stat-label">Deploys</div></div>
            <div class="stat"><div class="stat-val-sm" id="smRuns">0</div><div class="stat-label">Pipeline Runs</div></div>
        </div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.self_mod || {};
  const streak = s.streak || 0;
  const target = s.streakTarget || 20;
  const fill = document.getElementById('smStreakFill');
  const val = document.getElementById('smStreakVal');
  if (fill) fill.style.width = Math.min(100, Math.round((streak / target) * 100)) + '%';
  if (val) val.textContent = streak + ' / ' + target;
  const rm = document.getElementById('smReview');
  if (rm) rm.textContent = s.reviewMode || '—';
  const t = document.getElementById('smTask'); if (t) t.textContent = (s.taskSuccess || 0).toFixed(2);
  const l = document.getElementById('smLatency'); if (l) l.textContent = (s.latency || 0).toFixed(2);
  const k = document.getElementById('smKv'); if (k) k.textContent = (s.kv || 0).toFixed(2);
  const p = document.getElementById('smProposals'); if (p) p.textContent = s.proposals || 0;
  const d = document.getElementById('smDeploys'); if (d) d.textContent = s.deploys || 0;
  const r = document.getElementById('smRuns'); if (r) r.textContent = s.runs || 0;
})();
SCRIPTEOF
)

# Guarded: a malformed (non-numeric) field in a present state file must never
# abort the always-write guarantee — fall back to a minimal fragment.
DATA_JSON=$(jq -n --argjson taskSuccess "$TASK_SUCCESS" --argjson latency "$LATENCY" --argjson kv "$KV" \
    --argjson streak "$STREAK" --argjson streakTarget "$STREAK_TARGET" --arg lastEvent "$LAST_EVENT" \
    --arg reviewMode "$REVIEW_MODE" --arg lastUpdated "$LAST_UPDATED" \
    --argjson proposals "$PROPOSALS" --argjson deploys "$DEPLOYS" --argjson runs "$RUNS" \
    '{installed: true, taskSuccess: $taskSuccess, latency: $latency, kv: $kv, streak: $streak, streakTarget: $streakTarget, lastEvent: $lastEvent, reviewMode: $reviewMode, lastUpdated: $lastUpdated, proposals: $proposals, deploys: $deploys, runs: $runs}' \
    2>/dev/null) || DATA_JSON='{"installed": true}'

echo "$HTML" > /tmp/sm_frag_html.$$
echo "$SCRIPT" > /tmp/sm_frag_script.$$
jq -n --arg id "self_mod" --argjson order 55 --arg label "Self-Mod" --arg icon "🛠️" \
  --rawfile html /tmp/sm_frag_html.$$ --rawfile script /tmp/sm_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/self_mod.json"
rm -f /tmp/sm_frag_html.$$ /tmp/sm_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus self_mod
