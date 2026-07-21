#!/bin/bash
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"
OUTPUT_FILE="$WORKSPACE/PFC_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No PFC state found"; exit 1; }

OUTPUT_FILE="$OUTPUT_FILE" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
lines = ['# 🧭 Executive State', '']
lines.append(f\"Executive load: {state.get('executiveLoad', 0.3)}\")
lines.append('')
goals = [g for g in state.get('goals', []) if g.get('status') == 'active']
if goals:
    lines.append('## Active Goals')
    for g in sorted(goals, key=lambda x: -x.get('priority', 0.5)):
        lines.append(f\"- ({g.get('priority',0.5):.1f}) {g['description']}\")
    lines.append('')
inh = state.get('inhibitions', [])
if inh:
    lines.append('## Active Inhibitions')
    for i in inh:
        lines.append(f\"- {i['pattern']} — {i.get('reason','')}\")
    lines.append('')
recent = state.get('decisionLog', [])[:5]
if recent:
    lines.append('## Recent Decisions')
    for d in recent:
        lines.append(f\"- ({d.get('context','general')}) chose **{d.get('chosen','—')}** — {d.get('reasoning','')}\")
with open(os.environ['OUTPUT_FILE'], 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('✅ Synced to ' + os.environ['OUTPUT_FILE'])
"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/generate-dashboard.sh" ] && "$SCRIPT_DIR/generate-dashboard.sh" 2>/dev/null || true
