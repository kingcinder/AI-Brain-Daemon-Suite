#!/bin/bash
# generate-dashboard.sh — Write hippocampus's own dashboard fragment, then call
# the shared dashboard-builder.sh. Reads ONLY hippocampus's own state file.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
STATE_FILE="$WORKSPACE/memory/index.json"
mkdir -p "$FRAGMENTS_DIR"
[ ! -f "$STATE_FILE" ] && { echo "❌ No hippocampus state found"; exit 1; }

MEM_COUNT=$(jq '.memories | length' "$STATE_FILE")
CORE_COUNT=$(jq '[.memories[] | select((.importance // 0) >= 0.7)] | length' "$STATE_FILE")
TOP=$(jq -c '[.memories | sort_by(-(.importance // 0)) | .[:6] | .[] | {text: ((.content // "...")[:80] + "..."), importance: (.importance // 0)}]' "$STATE_FILE")

HTML=$(cat << 'HTMLEOF'
        <div class="card"><div class="stats">
          <div class="stat"><div class="stat-val" id="memCount">0</div><div class="stat-label">Total Memories</div></div>
          <div class="stat"><div class="stat-val" id="coreCount">0</div><div class="stat-label">Core (>=0.7)</div></div>
        </div></div>
        <div class="card"><div class="card-title">Top Memories</div><div id="topMemories"></div></div>
HTMLEOF
)

SCRIPT=$(cat << 'SCRIPTEOF'
(function () {
  const s = state.hippocampus;
  document.getElementById('memCount').textContent = s.memoryCount;
  document.getElementById('coreCount').textContent = s.coreCount;
  const el = document.getElementById('topMemories');
  if (s.topMemories && s.topMemories.length) {
    s.topMemories.forEach(m => {
      el.innerHTML += `<div class="list-item"><div class="list-text">${m.text}</div><div class="list-sub">importance ${m.importance.toFixed(2)}</div></div>`;
    });
  } else {
    el.innerHTML = '<div class="empty">No memories yet.</div>';
  }
})();
SCRIPTEOF
)

LAST_UPDATED=$(jq -r '.lastUpdated // "never"' "$STATE_FILE"); LAST_CONSULTED=$(jq -r '.lastConsultedAt // "never"' "$STATE_FILE")
DATA_JSON=$(jq -n --argjson memoryCount "$MEM_COUNT" --argjson coreCount "$CORE_COUNT" --argjson topMemories "$TOP" \
  --arg lastUpdated "$LAST_UPDATED" --arg lastConsultedAt "$LAST_CONSULTED" \
  '{installed: true, memoryCount: $memoryCount, coreCount: $coreCount, topMemories: $topMemories, lastUpdated: $lastUpdated, lastConsultedAt: $lastConsultedAt}')

echo "$HTML" > /tmp/hippo_frag_html.$$
echo "$SCRIPT" > /tmp/hippo_frag_script.$$
jq -n --arg id "hippocampus" --argjson order 10 --arg label "Memory" --arg icon "🧠" \
  --rawfile html /tmp/hippo_frag_html.$$ --rawfile script /tmp/hippo_frag_script.$$ --argjson data "$DATA_JSON" \
  '{id:$id, order:$order, label:$label, icon:$icon, html:$html, script:$script, data:$data}' \
  > "$FRAGMENTS_DIR/hippocampus.json"
rm -f /tmp/hippo_frag_html.$$ /tmp/hippo_frag_script.$$

"$SCRIPT_DIR/dashboard-builder.sh" --focus hippocampus
