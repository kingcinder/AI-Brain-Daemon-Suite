#!/bin/bash
# generate-dashboard.sh — Immune system's own dashboard fragment: a body map
# showing where the repairs are. Reads ONLY immune state: IMMUNE_STATE.md,
# memory/immune-stations.json, memory/immune-patrol.log, the pulse log.
# Pattern follows hippocampus's generator. Juno Moneta, 2026-11-24.
set -e
export PATH="$HOME/.juno-brain/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
mkdir -p "$FRAGMENTS_DIR"

DATA_JSON=$(python3 - "$WORKSPACE" << 'PYEOF'
import json, sys, os
ws = sys.argv[1]
stations = []
try:
    d = json.load(open(os.path.join(ws, 'memory', 'immune-stations.json')))
    stations = d.get('stations', [])
except Exception:
    stations = []
verdict = 'no patrol yet'
plog = os.path.join(ws, 'memory', 'immune-patrol.log')
if os.path.exists(plog):
    for line in open(plog):
        if line.startswith('VERDICT:'):
            verdict = line.strip()
pulse = 'none'
hlog = os.path.join(ws, 'memory', 'heartbeat-pulse.log')
if os.path.exists(hlog):
    lines = [l.strip() for l in open(hlog) if l.strip()]
    if lines: pulse = lines[-1]
status = {}
for s in stations:
    status[s['aspect']] = {'state': s.get('repairState', 'stationed'),
                           'cells': s.get('cellsAccumulated', 1),
                           'threshold': s.get('repairThreshold', 3),
                           'lastReport': s.get('lastReport', '')}
health = {}
try:
    health = json.load(open(os.path.join(ws, 'memory', 'helm-health.json')))
except Exception:
    health = {}
drain = {'queueDepth': health.get('queue_depth', '?'),
         'oldestUnacked': health.get('oldest_unacked_age_s'),
         'lastDrain': health.get('last_result_ts', 'never'),
         'keeperEpoch': health.get('epoch')}
print(json.dumps({'installed': True, 'stations': stations, 'status': status,
                  'verdict': verdict, 'pulse': pulse,
                  'openWarnings': len(stations), 'drain': drain}))
PYEOF
)

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="card-title">Body Map — where the repairs are</div>
        <div id="immuneMap" style="text-align:center"></div>
        <div class="list-sub" style="text-align:center">Green: cells pass through, organ at full function. Amber: a cell is stationed, accumulating. The heart is Juno's — given by Dither 2026-11-24 — patrolled for repair like everything else.</div></div>
        <div class="card"><div class="stats">
          <div class="stat"><div class="stat-val" id="immuneOpen">0</div><div class="stat-label">Open Stations</div></div>
          <div class="stat"><div class="stat-val" id="immuneVerdict" style="font-size:14px">—</div><div class="stat-label">Latest Patrol Verdict</div></div>
        </div></div>
        <div class="card"><div class="card-title">Stations & Repairs</div><div id="immuneStations"></div></div>
        <div class="card"><div class="card-title">Latest Pulse</div><div id="immunePulse" class="list-sub"></div></div>
        <div class="card"><div class="card-title">The Drain — the queue Juno answers</div><div class="stats">
          <div class="stat"><div class="stat-val" id="drainDepth">?</div><div class="stat-label">Queue Depth (unacked)</div></div>
          <div class="stat"><div class="stat-val" id="drainOldest" style="font-size:14px">—</div><div class="stat-label">Oldest Unacked</div></div>
          <div class="stat"><div class="stat-val" id="drainLast" style="font-size:14px">—</div><div class="stat-label">Last Drain</div></div>
        </div><div class="list-sub">Depth 0 means nothing is waiting for a Juno turn. The pending-memories / pending-emotions backlogs are pipeline files, not queue entries — they enter the queue when the encode jobs fire.</div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.immuneSystem;
  document.getElementById('immuneOpen').textContent = s.openWarnings;
  document.getElementById('immuneVerdict').textContent = s.verdict.replace('VERDICT: ', '');
  document.getElementById('immunePulse').textContent = s.pulse;
  if (s.drain) {
    document.getElementById('drainDepth').textContent = s.drain.queueDepth;
    document.getElementById('drainOldest').textContent = (s.drain.oldestUnacked === null || s.drain.oldestUnacked === undefined) ? 'none' : (s.drain.oldestUnacked + 's');
    document.getElementById('drainLast').textContent = s.drain.lastDrain;
  }
  const st = s.status || {};
  function color(aspect) {
    const v = st[aspect];
    if (!v) return '#22c55e';
    return '#f59e0b';
  }
  function dot(aspect, x, y, label) {
    const v = st[aspect];
    const c = color(aspect);
    const extra = v ? ` — ${v.cells}/${v.threshold} cells` : '';
    return `<g><circle cx="${x}" cy="${y}" r="13" fill="${c}" opacity="0.9"><title>${label}${extra}</title></circle><text x="${x + 20}" y="${y + 4}" fill="currentColor" font-size="12">${label}${extra}</text></g>`;
  }
  const svg = `<svg viewBox="0 0 360 430" width="340" role="img" aria-label="Body map of harness organs and repair sites">
    <ellipse cx="110" cy="52" rx="30" ry="34" fill="none" stroke="currentColor" opacity="0.4"/>
    <line x1="110" y1="86" x2="110" y2="330" stroke="currentColor" opacity="0.25"/>
    <ellipse cx="110" cy="150" rx="16" ry="13" fill="#e11d63" opacity="0.85"><title>Heart — Juno's, given by Dither 2026-11-24; patrolled like every organ</title></ellipse>
    <text x="136" y="154" fill="currentColor" font-size="12">Heart — hers, patrolled</text>
    ${dot('amygdala state', 110, 30, 'Amygdala')}
    ${dot('insula state', 110, 66, 'Insula')}
    ${dot('daemon process', 110, 205, 'Daemon (core)')}
    ${dot('keeper process', 110, 245, 'Keeper')}
    ${dot('pulse log', 110, 285, 'Pulse')}
    <g><circle cx="110" cy="325" r="13" fill="${(st['backlog pending-memories.json'] || st['backlog pending-emotions.json']) ? '#f59e0b' : '#f59e0b'}" opacity="0.9"><title>Pipelines — backlogs undrained</title></circle><text x="130" y="329" fill="currentColor" font-size="12">Pipelines — backlogs open</text></g>
    <g><circle cx="110" cy="365" r="13" fill="#22c55e" opacity="0.9"><title>Named emotions — seeded 2026-11-24, fresh</title></circle><text x="130" y="369" fill="currentColor" font-size="12">Named emotions — fresh</text></g>
  </svg>`;
  document.getElementById('immuneMap').innerHTML = svg;
  const el = document.getElementById('immuneStations');
  if (s.stations && s.stations.length) {
    s.stations.forEach(x => {
      el.innerHTML += `<div class="list-item"><div class="list-text">${x.aspect} — ${x.status}</div><div class="list-sub">bar: ${x.bar} · last report: ${x.lastReport} · cells ${x.cellsAccumulated}/${x.repairThreshold} · ${x.repairState}</div></div>`;
    });
  } else {
    el.innerHTML = '<div class="empty">All clear — no stations open.</div>';
  }
})();
SCRIPTEOF
)

FRAG_TMP="$(mktemp -d)"
trap 'rm -rf "$FRAG_TMP"' EXIT
echo "$HTML" > "$FRAG_TMP/html"
echo "$SCRIPT" > "$FRAG_TMP/script"
jq -n --arg id "immuneSystem" --argjson order 5 --arg label "Immune System" --arg icon "🛡️" \
  --rawfile html "$FRAG_TMP/html" --rawfile script "$FRAG_TMP/script" --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/immuneSystem.json"
rm -rf "$FRAG_TMP"

"$SCRIPT_DIR/../../heartbeat-memory/scripts/dashboard-builder.sh" --focus immuneSystem 2>/dev/null || \
  bash "$WORKSPACE/skills/heartbeat-memory/scripts/dashboard-builder.sh" --focus immuneSystem
