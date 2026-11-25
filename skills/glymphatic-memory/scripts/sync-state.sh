#!/bin/bash
# Glymphatic: render GLYMPHATIC_STATE.md from glymphatic-state.json
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
STATE_FILE="$WORKSPACE/memory/glymphatic-state.json"
OUTPUT_FILE="$WORKSPACE/GLYMPHATIC_STATE.md"
[ ! -f "$STATE_FILE" ] && { echo "❌ No glymphatic state found"; exit 1; }

python3 - "$STATE_FILE" "$OUTPUT_FILE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
t = state.get("totals", {})
last = state.get("lastSweep") or {}
lines = ["# 🌊 Glymphatic State", ""]
lines.append(f"Last sweep: {state.get('lastSweepAt') or 'never'}")
lines.append(f"Last consulted: {state.get('lastConsultedAt') or 'never'}")
lines.append("")
lines.append("## Lifetime totals")
lines.append(f"- Sweeps: {t.get('sweeps', 0)}")
lines.append(f"- Dead letters archived: {t.get('archived', 0)}")
lines.append(f"- Stale leases reaped: {t.get('reaped', 0)}")
lines.append(f"- Overstay escalations: {t.get('escalated', 0)}")
lines.append(f"- Orphan stores reported: {t.get('orphansReported', 0)}")
if last:
    lines.append("")
    lines.append("## Last sweep")
    lines.append(f"- Found: {last.get('found', 0)} items across audited stores")
    lines.append(f"- Archived: {last.get('archived', 0)} · Reaped: {last.get('reaped', 0)} · Escalated: {last.get('escalated', 0)} · Reported: {last.get('reported', 0)} · Retained: {last.get('retained', 0)}")
    for note in last.get("notes", [])[:8]:
        lines.append(f"- {note}")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print(f"✅ Synced to {sys.argv[2]}")
PY
