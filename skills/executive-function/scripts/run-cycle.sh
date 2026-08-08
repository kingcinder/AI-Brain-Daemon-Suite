#!/bin/bash
# Daemon entrypoint for Phase 2 executive cycle.
# Resolves core/executive either from WORKSPACE (installed) or suite tree (dev).

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prefer workspace-installed core (install.sh deploys core/ next to skills/)
if [ -x "$WORKSPACE/core/executive/run-executive-cycle.sh" ]; then
  CORE_EXEC="$WORKSPACE/core/executive/run-executive-cycle.sh"
elif [ -x "$SCRIPT_DIR/../../../core/executive/run-executive-cycle.sh" ]; then
  # Dev: skills/executive-function/scripts -> suite root
  CORE_EXEC="$(cd "$SCRIPT_DIR/../../.." && pwd)/core/executive/run-executive-cycle.sh"
else
  echo "run-cycle.sh: cannot locate core/executive/run-executive-cycle.sh" >&2
  echo "  checked: $WORKSPACE/core/executive/ and suite-relative path" >&2
  exit 1
fi

# Run the cycle with the daemon's Pillar 3 shutdown semantics preserved: this
# wrapper is the tracked PID, so forward TERM/INT to the real worker rather
# than letting a timeout-kill orphan it (the daemon signals only this PID).
rc=0
bash "$CORE_EXEC" --workspace "$WORKSPACE" "$@" &
CYCLE_PID=$!
trap 'kill "$CYCLE_PID" 2>/dev/null || true' TERM INT
wait "$CYCLE_PID" || rc=$?
trap - TERM INT
# Keep the 🎛️ Governance tab fresh with this cycle's load/goals/reflections.
# (Runs on failure too — the tab should show the latest state either way.)
[ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && bash "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true
exit "$rc"
