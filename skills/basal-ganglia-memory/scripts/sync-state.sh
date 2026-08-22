#!/bin/bash
# sync-state.sh — Sync habit-state.json to BASAL_GANGLIA_STATE.md and
# regenerate the shared brain-dashboard.html
#
# BASAL_GANGLIA_STATE.md is the auto-injected context file: chunked habits
# (fire automatically), active procedures, and active suppressions. This is
# the basal-ganglia analog of hippocampus's HIPPOCAMPUS_CORE.md.
#
# Environment:
#   WORKSPACE - OpenClaw workspace directory (default: ~/.hermes/workspace)
#   CHUNK_THRESHOLD - Minimum strength for "chunked" habits (default: 0.7)
#   ACTIVE_THRESHOLD - Minimum strength for procedures/suppressions (default: 0.4)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
OUTPUT="$WORKSPACE/BASAL_GANGLIA_STATE.md"
CHUNK_THRESHOLD="${CHUNK_THRESHOLD:-0.7}"
ACTIVE_THRESHOLD="${ACTIVE_THRESHOLD:-0.4}"

if [ ! -f "$STATE_FILE" ]; then
    echo "No basal-ganglia state found at $STATE_FILE"
    exit 0
fi

STATE_FILE="$STATE_FILE" OUTPUT="$OUTPUT" CHUNK_THRESHOLD="$CHUNK_THRESHOLD" ACTIVE_THRESHOLD="$ACTIVE_THRESHOLD" \
python3 << 'PYTHON'
import json
import os
from datetime import datetime, timezone

STATE_FILE = os.environ["STATE_FILE"]
OUTPUT_PATH = os.environ["OUTPUT"]
CHUNK_THRESHOLD = float(os.environ["CHUNK_THRESHOLD"])
ACTIVE_THRESHOLD = float(os.environ["ACTIVE_THRESHOLD"])

with open(STATE_FILE) as f:
    state = json.load(f)

habits = state.get('habits', [])
procedures = state.get('procedures', [])
suppressions = state.get('suppressions', [])

chunked = sorted([h for h in habits if h.get('strength', 0) >= CHUNK_THRESHOLD],
                  key=lambda h: -h.get('strength', 0))
active = sorted([h for h in habits if ACTIVE_THRESHOLD <= h.get('strength', 0) < CHUNK_THRESHOLD],
                 key=lambda h: -h.get('strength', 0))
active_procs = sorted([p for p in procedures if p.get('strength', 0) >= ACTIVE_THRESHOLD],
                       key=lambda p: -p.get('strength', 0))
active_supps = sorted([s for s in suppressions if s.get('strength', 0) >= 0.3],
                       key=lambda s: -s.get('strength', 0))

lines = [
    "# Basal Ganglia State",
    "",
    f"*Auto-generated from habit-state.json | "
    f"{len(chunked)} chunked, {len(active)} active, "
    f"{len(active_procs)} procedures, {len(active_supps)} suppressions*",
    f"*Last sync: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}*",
    "",
    "These are this agent's established habits, procedures, and suppressions. "
    "Chunked habits fire automatically; active habits should still be applied "
    "deliberately; suppressions are patterns to actively avoid.",
    "",
]

if chunked:
    lines.append("## 🟢 Chunked Habits (fire automatically)")
    lines.append("")
    for h in chunked:
        lines.append(
            f"- **When** {h.get('cue', '?')} **→** {h.get('routine', '?')} "
            f"*(reward: {h.get('reward', '?')}; strength {h.get('strength', 0):.2f}, "
            f"{h.get('executions', 0)} runs)*"
        )
    lines.append("")

if active:
    lines.append("## 🟡 Active Habits (apply deliberately)")
    lines.append("")
    for h in active:
        lines.append(
            f"- **When** {h.get('cue', '?')} **→** {h.get('routine', '?')} "
            f"*(strength {h.get('strength', 0):.2f}, {h.get('executions', 0)} runs)*"
        )
    lines.append("")

if active_procs:
    lines.append("## 🧩 Procedures")
    lines.append("")
    for p in active_procs:
        steps = " → ".join(p.get('steps', []))
        lines.append(f"- **{p.get('name', '?')}**: {steps} *(strength {p.get('strength', 0):.2f})*")
    lines.append("")

if active_supps:
    lines.append("## 🚫 Suppressions (actively avoid)")
    lines.append("")
    for s in active_supps:
        lines.append(f"- Avoid: {s.get('pattern', '?')} — {s.get('reason', 'no reason given')} "
                      f"*(strength {s.get('strength', 0):.2f})*")
    lines.append("")

if not (chunked or active or active_procs or active_supps):
    lines.append("_No established habits yet. Every approach is still fresh/deliberate._")
    lines.append("")

with open(OUTPUT_PATH, 'w') as f:
    f.write('\n'.join(lines))

print(f"🎯 Synced {len(chunked)} chunked habits, {len(active)} active habits, "
      f"{len(active_procs)} procedures, {len(active_supps)} suppressions "
      f"to {OUTPUT_PATH}")
PYTHON

# Regenerate brain dashboard (best-effort — basal-ganglia owns the
# "Habits" tab but the dashboard is shared across all installed brain skills)
[ -x "$SKILL_DIR/scripts/generate-dashboard.sh" ] && \
    WORKSPACE="$WORKSPACE" "$SKILL_DIR/scripts/generate-dashboard.sh" || true
