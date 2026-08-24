#!/bin/bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
OUTPUT_FILE="$WORKSPACE/SOCIAL_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

OUTPUT_FILE="$OUTPUT_FILE" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
state = json.load(open(os.environ['STATE_FILE']))
rels = state.get('relationships', {})
lines = ['# 🫂 Social State', '']
lines.append(f\"Known relationships: {len(rels)}\")
lines.append('')
open_loops = []
for rid, r in rels.items():
    for loop in r.get('openLoops', []):
        if loop.get('status') == 'open':
            open_loops.append((r['name'], loop['description']))
if open_loops:
    lines.append('## Open Loops')
    for name, desc in open_loops:
        lines.append(f\"- {name}: {desc}\")
    lines.append('')
if rels:
    lines.append('## Relationships')
    for rid, r in sorted(rels.items(), key=lambda kv: kv[1].get('lastContact') or '', reverse=True)[:10]:
        lines.append(f\"- {r['name']} ({r['type']}) — trust {r.get('trust',0.5):.2f}, affinity {r.get('affinity',0.5):.2f}\")
spe = state.get('recentSPE', [])
if spe:
    lines.append('')
    lines.append('## Social Prediction Errors (Behrens social-value learning)')
    for e in reversed(spe[-5:]):
        lines.append(f\"- {e.get('id','?')}: expected {e.get('expected',0):.2f} → outcome {e.get('outcome',0):.2f}, SPE {e.get('spe',0):+.3f}\")
with open(os.environ['OUTPUT_FILE'], 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('✅ Synced to ' + os.environ['OUTPUT_FILE'])
"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/generate-dashboard.sh" ] && "$SCRIPT_DIR/generate-dashboard.sh" 2>/dev/null || true
