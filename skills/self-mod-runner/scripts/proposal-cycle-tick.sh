#!/bin/bash
# Daemon entry: scheduled self-mod proposal cycle (ROADMAP M1).
#
# Runs core/self-mod/run-pipeline.sh with LLM-backed proposal generation and
# the M2 autonomy gate (--autonomy-gate): in relaxed_review the pipeline may
# auto-deploy the top accepted proposal; in full_review it queues for human
# approval instead. LLM provider failure is non-fatal — run-pipeline records
# it and continues with whatever is already queued in the store.
#
# --defer-gate (added with the M8 audit trail): when the refreshed autonomy
# contract is steward_mode + full_review, the cycle DEFERS the whole run
# instead of churning through generation/evaluation only to skip the deploy
# at the end. The deferral is written to pipeline-runs/latest.json and logged
# as a provenance event (autonomy.gate.deferred), so the weekly cycle's
# behavior is fully auditable — the human is the operator until they grant
# auto_mode or relax review.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$WORKSPACE/core/self-mod/run-pipeline.sh" ]; then
  PIPELINE="$WORKSPACE/core/self-mod/run-pipeline.sh"
  SUITE_ROOT="$WORKSPACE"
elif [ -x "$SCRIPT_DIR/../../../core/self-mod/run-pipeline.sh" ]; then
  SUITE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  PIPELINE="$SUITE_ROOT/core/self-mod/run-pipeline.sh"
else
  echo "proposal-cycle-tick: core/self-mod/run-pipeline.sh not found" >&2
  exit 1
fi

# Ensure the stderr log directory exists before the redirect is opened
# (run-pipeline.sh creates its own dirs, but the redirect happens first).
mkdir -p "$WORKSPACE/memory/self-mod"

# M8: refresh the M7 autonomy contract from fresh evidence before the cycle
# decides — a stale autonomy-state.json must not auto-deploy (or wrongly
# block) this run. --autonomy is read-only; best-effort (never fails the tick).
KERNEL="$SUITE_ROOT/deep-brain-kernel.py"
if [ -f "$KERNEL" ]; then
  WORKSPACE="$WORKSPACE" python3 "$KERNEL" --autonomy >/dev/null 2>&1 || true
fi

# Forward the daemon's TERM/INT (it signals only this tracked PID — Pillar 3)
# to the pipeline so a timeout-kill can't orphan a running proposal cycle.
rc=0
bash "$PIPELINE" \
  --suite-root "$SUITE_ROOT" \
  --workspace "$WORKSPACE" \
  --generate-llm \
  --autonomy-gate \
  --defer-gate \
  2>"$WORKSPACE/memory/self-mod/proposal-cycle.err" &
PIPE_PID=$!
trap 'kill "$PIPE_PID" 2>/dev/null || true' TERM INT
wait "$PIPE_PID" || rc=$?
trap - TERM INT
# Keep the 🛠️ Self-Mod tab fresh with the updated proposal store + streak.
[ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && bash "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true
if [ "$rc" -ne 0 ]; then
  echo "proposal-cycle-tick: pipeline failed — see $WORKSPACE/memory/self-mod/proposal-cycle.err" >&2
  exit 1
fi
