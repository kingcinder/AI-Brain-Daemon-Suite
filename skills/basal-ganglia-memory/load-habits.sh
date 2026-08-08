#!/bin/bash
# load-habits.sh — Output active habits, procedures, and suppressions for
# session context injection (analogous to hippocampus's load-core.sh)
#
# Usage:
#   load-habits.sh                 # Prose format (default)
#   load-habits.sh --format brief  # One-line summary
#   load-habits.sh --format json   # Raw JSON of chunked+active items
#
# Environment:
#   WORKSPACE - OpenClaw workspace directory (default: ~/.hermes/workspace)
#   THRESHOLD - Minimum strength for "active" inclusion (default: 0.4)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
THRESHOLD="${THRESHOLD:-0.4}"

if [ ! -f "$STATE_FILE" ]; then
    echo "No basal ganglia state found at $STATE_FILE"
    exit 0
fi

FORMAT="prose"
[ "$1" = "--format" ] && FORMAT="$2"

export LH_STATE_FILE="$STATE_FILE"
export LH_THRESHOLD="$THRESHOLD"
export LH_FORMAT="$FORMAT"

python3 << 'PYTHON'
import json
import os

STATE_FILE = os.environ["LH_STATE_FILE"]
THRESHOLD = float(os.environ["LH_THRESHOLD"])
FORMAT = os.environ["LH_FORMAT"]

with open(STATE_FILE) as f:
    state = json.load(f)

habits = state.get("habits", [])
procedures = state.get("procedures", [])
suppressions = state.get("suppressions", [])

chunked = sorted([h for h in habits if h.get("strength", 0) >= 0.7], key=lambda h: -h.get("strength", 0))
active = sorted([h for h in habits if THRESHOLD <= h.get("strength", 0) < 0.7], key=lambda h: -h.get("strength", 0))
active_procs = sorted([p for p in procedures if p.get("strength", 0) >= THRESHOLD], key=lambda p: -p.get("strength", 0))
active_supps = sorted([s for s in suppressions if s.get("strength", 0) >= 0.3], key=lambda s: -s.get("strength", 0))

if FORMAT == "json":
    print(json.dumps({
        "chunked": chunked,
        "active": active,
        "procedures": active_procs,
        "suppressions": active_supps,
    }, indent=2))

elif FORMAT == "brief":
    print(f"Habits: {len(chunked)} chunked, {len(active)} active, {len(active_procs)} procedures, {len(active_supps)} suppressions")

else:  # prose
    if not chunked and not active and not active_procs and not active_supps:
        print("🎯 No established habits yet. Every approach is still fresh/deliberate.")
    else:
        print("🎯 BASAL GANGLIA: habits and routines for this session")
        print()

        if chunked:
            print("**Chunked (fire automatically when the cue appears):**")
            for h in chunked:
                print(f"  • When {h.get('cue','?')} → {h.get('routine','?')}  (strength {h.get('strength',0):.2f}, {h.get('executions',0)} runs)")
            print()

        if active:
            print("**Active (apply deliberately — still solidifying):**")
            for h in active:
                print(f"  • When {h.get('cue','?')} → {h.get('routine','?')}  (strength {h.get('strength',0):.2f}, {h.get('executions',0)} runs)")
            print()

        if active_procs:
            print("**Procedures (chunked workflows):**")
            for p in active_procs:
                steps = " → ".join(p.get("steps", []))
                print(f"  • {p.get('name','?')}: {steps}  (strength {p.get('strength',0):.2f})")
            print()

        if active_supps:
            print("**Suppressions (actively avoid these patterns):**")
            for s in active_supps:
                print(f"  • Avoid: {s.get('pattern','?')} — {s.get('reason','no reason given')}")
            print()
PYTHON

# Best-effort staleness tracking: record that this state was actually read,
# separate from lastUpdated (write path). Never blocks or fails the output above.
exec 200>"$STATE_FILE.lock"
flock 200
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
