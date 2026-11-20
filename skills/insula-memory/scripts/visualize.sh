#!/usr/bin/env bash
# visualize.sh — Terminal ASCII visualization of interoceptive state
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
[ ! -f "$STATE_FILE" ] && echo "No state file" && exit 0

python3 - "$STATE_FILE" << 'PYTHON'
import json, sys
s = json.load(open(sys.argv[1]))
c = s.get('channels', {})
W = 24
def bar(v, lo=-1, hi=1):
    pct = max(0, min(1, (v - lo) / (hi - lo)))
    filled = round(pct * W)
    return '█' * filled + '░' * (W - filled)
print("\n🌡️ Interoceptive State")
print("═" * 50)
rows = [
    ('gutSignal','Gut Signal','🎯',-1,1),
    ('cognitiveLoad','Cognitive Load','🧠',0,1),
    ('friction','Friction','🌊',0,1),
    ('somaticComfort','Somatic Comfort','🌿',-1,1),
    ('empathicResonance','Empathic Resonance','💕',0,1),
    ('selfCoherence','Self Coherence','🔮',0,1),
    ('contextSaturation','Context Saturation','📊',0,1),
]
for k, label, icon, lo, hi in rows:
    v = c.get(k, 0)
    b = bar(v, lo, hi)
    print(f"{icon} {label:<22} [{b}] {v:+.2f}")
print()
PYTHON
