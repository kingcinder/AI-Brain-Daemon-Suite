#!/bin/bash
# Daemon entry: scheduled self-mod proposal cycle (ROADMAP M1).
#
# Runs core/self-mod/run-pipeline.sh with LLM-backed proposal generation and
# the M2 autonomy gate (--autonomy-gate): in relaxed_review the pipeline may
# auto-deploy the top accepted proposal; in full_review it queues for human
# approval instead. LLM provider failure is non-fatal — run-pipeline records
# it and continues with whatever is already queued in the store.
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

bash "$PIPELINE" \
  --suite-root "$SUITE_ROOT" \
  --workspace "$WORKSPACE" \
  --generate-llm \
  --autonomy-gate \
  2>"$WORKSPACE/memory/self-mod/proposal-cycle.err" \
  || {
    echo "proposal-cycle-tick: pipeline failed — see $WORKSPACE/memory/self-mod/proposal-cycle.err" >&2
    exit 1
  }
