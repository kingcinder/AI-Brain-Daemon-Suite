#!/bin/bash
# Claustrum: render CORTICAL_STATE.md from claustrum-state.json
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
STATE_FILE="$WORKSPACE/memory/claustrum-state.json"
OUTPUT_FILE="$WORKSPACE/CORTICAL_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No claustrum state found"; exit 1; }
python3 - "$STATE_FILE" "$OUTPUT_FILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
lb = s.get("lastBinding") or {}
lines = ["# 🧩 Cortical State (Claustrum binding)", ""]
lines.append(f"Last binding: {s.get('lastBoundAt') or 'never'}")
lines.append(f"Last consulted: {s.get('lastConsultedAt') or 'never'}")
lines.append(f"Organs bound: {lb.get('organCount', 0)}")
lines.append("")
lines.append("## Coherence")
incs = lb.get("incoherences") or []
if incs:
    for i in incs:
        lines.append(f"- ⚠️ {i['organ']}: {i['kind']} — {i.get('detail', '')}")
else:
    lines.append("- coherent — every organ consulted within its window")
t = s.get("totals") or {}
lines.append("")
lines.append(f"Bindings: {t.get('bindings', 0)} · incoherences (lifetime): {t.get('incoherences', 0)}")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print(f"✅ Synced to {sys.argv[2]}")
PY
