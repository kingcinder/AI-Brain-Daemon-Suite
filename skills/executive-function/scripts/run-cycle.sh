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

exec bash "$CORE_EXEC" --workspace "$WORKSPACE" "$@"
