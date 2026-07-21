#!/bin/bash
# Daemon entry: post-deploy self-mod monitor (Phase 3).
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$WORKSPACE/core/self-mod/monitor.sh" ]; then
  exec bash "$WORKSPACE/core/self-mod/monitor.sh" --workspace "$WORKSPACE"
elif [ -x "$SCRIPT_DIR/../../../core/self-mod/monitor.sh" ]; then
  exec bash "$SCRIPT_DIR/../../../core/self-mod/monitor.sh" --workspace "$WORKSPACE"
else
  echo "monitor-tick: core/self-mod/monitor.sh not found" >&2
  exit 1
fi
