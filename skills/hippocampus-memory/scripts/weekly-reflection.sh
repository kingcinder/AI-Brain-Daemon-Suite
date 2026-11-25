#!/bin/bash
# weekly-reflection.sh — hippocampus weekly reflection gate.
#
# Companion to weekly-consolidation.sh (Dyther decision #8, 2026-11-08).
# Day-gating lives in the scheduler, not here: since Stage 4 (2026-11-10)
# this script is invoked only by the goal-owned Sunday cron
# hippocampus-weekly-reflection (03:56 Pacific), an hour after
# consolidation, so reflection reads the consolidated week. The old
# in-script Sunday self-gate was removed 2026-11-13 (Stage 4 gate push) —
# the script enqueues whenever it is invoked.

set -u

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
export WORKSPACE

OC_BIN="$(command -v openclaw 2>/dev/null || echo "$HOME/.local/bin/openclaw")"
if [ ! -x "$OC_BIN" ]; then
  echo "weekly-reflection: openclaw shim not found — cannot enqueue" >&2
  exit 1
fi

"$OC_BIN" sessions:spawn --label hippocampus_weekly_reflection --task "Run hippocampus WEEKLY REFLECTION (Sunday, after consolidation): 1. Read this week's consolidated memories and daily notes in ~/.openclaw/workspace/memory 2. Follow skills/hippocampus-memory/prompts/self-reflect.md and prompts/weekly-reflection-event.md: find patterns, themes, growth edges, unresolved loops across the week 3. Note where the week's record disagrees with long-term memory and flag it explicitly rather than smoothing it over 4. Write the reflection into the weekly section of the core memory file 5. Report the three sharpest observations"
