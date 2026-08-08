#!/bin/bash
# Daemon entry: post-deploy self-mod monitor (Phase 3).
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$WORKSPACE/core/self-mod/monitor.sh" ]; then
  MONITOR="$WORKSPACE/core/self-mod/monitor.sh"
elif [ -x "$SCRIPT_DIR/../../../core/self-mod/monitor.sh" ]; then
  MONITOR="$(cd "$SCRIPT_DIR/../../.." && pwd)/core/self-mod/monitor.sh"
else
  echo "monitor-tick: core/self-mod/monitor.sh not found" >&2
  exit 1
fi

# Forward the daemon's TERM/INT (it signals only this tracked PID — Pillar 3)
# to the real worker so a timeout-kill can't orphan the monitor run.
rc=0
bash "$MONITOR" --workspace "$WORKSPACE" &
MON_PID=$!
trap 'kill "$MON_PID" 2>/dev/null || true' TERM INT
wait "$MON_PID" || rc=$?
trap - TERM INT
# Keep the 🛠️ Self-Mod tab fresh with live metrics + graduation streak.
[ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && bash "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true
exit "$rc"
