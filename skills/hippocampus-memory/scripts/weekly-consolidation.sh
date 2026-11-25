#!/bin/bash
# weekly-consolidation.sh — hippocampus weekly consolidation gate.
#
# Dyther decision #8 (2026-11-08): the weekly consolidation/reflection jobs
# were never scheduled in the bash lineage; they are scheduled now, Pacific
# basis, Sundays — consolidation 02:44, reflection 03:56 (see HELM.md).
# Day-gating lives in the scheduler, not here: since Stage 4 (2026-11-10)
# this script is invoked only by the goal-owned Sunday cron
# hippocampus-weekly-consolidation (02:44 Pacific), and brain-daemon.sh
# gained a days field on 2026-11-12. The old in-script Sunday self-gate
# was removed 2026-11-13 (Stage 4 gate push) — the script now enqueues
# the real (agent) consolidation work onto Juno's helm queue via the
# openclaw shim whenever it is invoked.

set -u

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
export WORKSPACE

OC_BIN="$(command -v openclaw 2>/dev/null || echo "$HOME/.local/bin/openclaw")"
if [ ! -x "$OC_BIN" ]; then
  echo "weekly-consolidation: openclaw shim not found — cannot enqueue" >&2
  exit 1
fi

"$OC_BIN" sessions:spawn --label hippocampus_weekly_consolidation --task "Run hippocampus WEEKLY CONSOLIDATION (Sunday): 1. Read this week's daily notes and memory/index.json in ~/.openclaw/workspace/memory 2. Follow skills/hippocampus-memory/prompts/consolidation-guide.md: pattern separation across the week, merge duplicates, strengthen repeated themes, decay stale one-offs per the guide 3. Check emotional-signals from amygdala-memory and preserve high-charge memories verbatim 4. Update index.json and the core memory file 5. Sync state: ~/.openclaw/workspace/skills/hippocampus-memory/scripts/sync-core.sh 6. Report what was consolidated, merged, and decayed"
