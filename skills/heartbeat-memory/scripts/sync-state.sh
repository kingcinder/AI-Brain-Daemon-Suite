#!/bin/bash
# sync-state.sh — Generate HEARTBEAT_STATE.md for session injection
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
OUTPUT_FILE="$WORKSPACE/HEARTBEAT_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No heartbeat state found"; exit 1; }

OUTPUT_FILE="$OUTPUT_FILE" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
lines = ['# 💓 Heartbeat', '']
lines.append(f\"Beats so far: {state.get('beatCount', 0)} | Last beat: {state.get('lastBeat') or 'never'}\")
lines.append(f\"Last chosen action: {state.get('lastChosenAction') or 'none'}\")
lines.append('')
active = [p for p in state.get('projects', []) if p.get('status') == 'active']
if active:
    lines.append('## Active Projects')
    for p in active:
        lines.append(f\"- [{p['type']}] {p['title']}\" + (f\" — {p['note']}\" if p.get('note') else ''))
    lines.append('')
hist = state.get('actionHistory', [])[:5]
if hist:
    lines.append('## Recent Actions')
    for h in hist:
        tag = ' (skipped)' if h.get('skipped') else ''
        lines.append(f\"- {h['action']}{tag}: {h.get('note','')}\")
with open(os.environ['OUTPUT_FILE'], 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('✅ Synced to ' + os.environ['OUTPUT_FILE'])
"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/generate-dashboard.sh" ]; then
    "$SCRIPT_DIR/generate-dashboard.sh" 2>/dev/null || true
fi
