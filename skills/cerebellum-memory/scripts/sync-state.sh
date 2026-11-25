#!/bin/bash
set -e
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
OUTPUT_FILE="$WORKSPACE/CEREBELLUM_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No cerebellum state found"; exit 1; }

python3 -c "
import json
state = json.load(open('$STATE_FILE'))
lines = ['# 🎚️ Cerebellum State', '']
lines.append(f\"Global calibration: {state.get('globalCalibration', 0.5):.2f}\")
lines.append('')
skills = state.get('skills', {})
if skills:
    lines.append('## Tracked Skills')
    for name, s in sorted(skills.items(), key=lambda kv: -kv[1].get('precision', 0)):
        pe = s.get('predictionError')
        pe_str = f\", prediction error {pe:.3f}\" if isinstance(pe, (int, float)) else ''
        lines.append(f\"- {name}: precision {s.get('precision',0.5):.2f}, smoothness {s.get('smoothness',0.5):.2f} ({s.get('reps',0)} reps){pe_str}\")
with open('$OUTPUT_FILE', 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('✅ Synced to $OUTPUT_FILE')
"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/generate-dashboard.sh" ] && "$SCRIPT_DIR/generate-dashboard.sh" 2>/dev/null || true
