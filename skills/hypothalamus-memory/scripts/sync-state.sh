#!/bin/bash
# Hypothalamus: render HYPOTHALAMUS_STATE.md from state
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
STATE_FILE="$WORKSPACE/memory/hypothalamus-state.json"
OUTPUT_FILE="$WORKSPACE/HYPOTHALAMUS_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No hypothalamus state found"; exit 1; }
python3 - "$STATE_FILE" "$OUTPUT_FILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
lines = ["# 🌡️ Hypothalamus State", ""]
lines.append(f"Last regulation pass: {s.get('lastRegulatedAt') or 'never'}")
lines.append(f"Last consulted: {s.get('lastConsultedAt') or 'never'}")
lines.append("")
lines.append("## Milieu variables vs set-points")
v = s.get("variables") or {}
sp = s.get("setpoints") or {}
for k in sorted(v):
    lines.append(f"- {k}: {v[k]}")
lines.append("")
lines.append("## Active corrective drives")
drives = s.get("activeDrives") or []
if drives:
    for d in drives:
        lines.append(f"- {d['variable']}={d['value']} (setpoint {d['direction']} {d['setpoint']}) → {d['destination']}")
else:
    lines.append("- none — milieu within bounds")
t = s.get("totals") or {}
lines.append("")
lines.append(f"Passes: {t.get('passes', 0)} · drives issued (lifetime): {t.get('drivesIssued', 0)}")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print(f"✅ Synced to {sys.argv[2]}")
PY
