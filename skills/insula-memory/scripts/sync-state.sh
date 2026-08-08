#!/usr/bin/env bash
# sync-state.sh — Generate INSULA_STATE.md from interoceptive-state.json
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
STATE_MD="$WORKSPACE/INSULA_STATE.md"
[ ! -f "$STATE_FILE" ] && echo "No state file" && exit 0

python3 - "$STATE_FILE" "$STATE_MD" << 'PYTHON'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

state = json.load(open(sys.argv[1]))
c = state.get('channels', {})
now = datetime.now(timezone.utc).strftime('%b %d, %Y %H:%M UTC')

def desc(k, v):
    d = {
        'gutSignal':    [(-1,-.4,'strong discord'),(-.4,-.1,'mild discord'),(-.1,.1,'neutral'),(.1,.4,'quiet ease'),(.4,1,'deep rightness')],
        'cognitiveLoad':[(0,.2,'very light'),(.2,.4,'light'),(.4,.6,'moderate'),(.6,.8,'heavy'),(.8,1,'very heavy')],
        'friction':     [(0,.2,'minimal'),(.2,.4,'light'),(.4,.6,'moderate'),(.6,.8,'significant'),(.8,1,'high')],
        'somaticComfort':[(-1,-.4,'contracted'),(-.4,-.1,'slightly contracted'),(-.1,.1,'neutral'),(.1,.4,'at ease'),(.4,1,'open/expansive')],
        'empathicResonance':[(0,.2,'distant'),(.2,.4,'present'),(.4,.7,'attuned'),(.7,1,'highly attuned')],
        'selfCoherence':[(0,.3,'fragmented'),(.3,.5,'somewhat fragmented'),(.5,.75,'coherent'),(.75,1,'fully coherent')],
        'contextSaturation':[(0,.3,'clear'),(.3,.5,'filling'),(.5,.7,'crowded'),(.7,1,'saturated')],
    }
    for lo, hi, label in d.get(k, []):
        if lo <= v <= hi: return label
    return str(round(v, 2))

lines = [f"## 🌡️ Insula — Interoceptive State\n*{now}*\n"]
for k, label in [
    ('gutSignal','Gut Signal'), ('cognitiveLoad','Cognitive Load'), ('friction','Friction'),
    ('somaticComfort','Somatic Comfort'), ('empathicResonance','Empathic Resonance'),
    ('selfCoherence','Self Coherence'), ('contextSaturation','Context Saturation')
]:
    v = c.get(k, 0)
    lines.append(f"{label}: {v:+.2f} ({desc(k,v)})")

recent = state.get('recentSignals', [])[-3:]
if recent:
    lines.append("\nRecent signals:")
    for sig in reversed(recent):
        lines.append(f"  {sig.get('label','?')} ({sig.get('intensity',0):.1f}) — {sig.get('source','')[:80]}")

Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
print("✅ INSULA_STATE.md updated")
PYTHON
