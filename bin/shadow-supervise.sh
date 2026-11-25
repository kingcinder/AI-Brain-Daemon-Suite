#!/bin/bash
# shadow-supervise.sh — Stage 2 shadow-run supervisor (AI Brain Daemon → Juno
# integration). This VM has no user-systemd bus (systemctl --user cannot
# connect), so this script provides the equivalent supervision systemd gives
# codypc's aibrain.service / helm-keeper.service (Restart=always):
#   - detached launch via setsid (survives shell/session exit)
#   - PID files under ~/.juno-brain/run/
#   - stdout/stderr to ~/.juno-brain/logs/
#   - restart-on-death is driven by shadow-watchdog.sh (cron, ~10 min),
#     which calls this script's start-* subcommands.
# SHADOW ONLY: everything is pinned to ~/.juno-brain/workspace-shadow.
# The pristine transplant (~/.juno-brain/workspace) and codypc's live
# suite are never touched by this script.
set -u

SHADOW="$HOME/.juno-brain/workspace-shadow"
RUN_DIR="$HOME/.juno-brain/run"
LOG_DIR="$HOME/.juno-brain/logs"
DAEMON_PID_FILE="$RUN_DIR/aibrain-shadow.pid"
KEEPER_PID_FILE="$RUN_DIR/helm-keeper-shadow.pid"
DAEMON_LOG="$LOG_DIR/aibrain-shadow.log"
KEEPER_LOG="$LOG_DIR/helm-keeper-shadow.log"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

mkdir -p "$RUN_DIR" "$LOG_DIR"

ts() { TZ=America/Los_Angeles date +"%Y-%m-%dT%H:%M:%S %Z"; }
# Phase 1a forensics (2026-11-09, refactor plan): boot_id stamp on every
# supervisor log line, matching shadow-watchdog.sh.
BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)

# Phase 2 identity refactor (2026-11-09, refactor plan): a pidfile is an
# identity claim, not a number. v2 format: "<pid> <starttime> <boot>".
# Liveness requires ALL of: pid exists, boot matches the current boot, and
# the process starttime matches (defeats PID reuse in a fresh namespace
# after VM replacement — the 2026-11-09 11:03 false-alive). Legacy v1
# pidfiles (bare pid) fall back to a cmdline-marker identity check.
proc_start() { # proc_start <pid> → starttime ticks or empty
  [ -r "/proc/$1/stat" ] || return 1
  sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}

write_pidfile() { # write_pidfile <file> <pid>
  echo "$2 $(proc_start "$2") $(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$1"
}

alive() { # alive <pidfile> <cmdline-marker> → echoes pid if identity verified
  local f="$1" marker="$2" pid start boot cur_start
  [ -f "$f" ] || return 1
  read -r pid start boot < "$f" || true
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null || return 1
  if [ -n "${start:-}" ] && [ -n "${boot:-}" ]; then
    [ "$boot" = "$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" ] || return 1
    cur_start=$(proc_start "$pid") || return 1
    [ "$cur_start" = "$start" ] || return 1
  else
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$marker" || return 1
  fi
  echo "$pid"; return 0
}

start_daemon() {
  local pid
  if pid=$(alive "$DAEMON_PID_FILE" "workspace-shadow/brain-daemon.sh"); then
    echo "daemon already running (pid $pid)"
    return 0
  fi
  # Adopt before launch (defect found 2026-11-09, Phase 3b): if a real
  # instance is already running but the pidfile is stale/corrupt, adopt it
  # and heal the pidfile — NEVER launch a duplicate alongside it.
  pid=$(pgrep -f "workspace-shadow/brain-daemon.sh" | head -1 || true)
  if [ -n "$pid" ]; then
    write_pidfile "$DAEMON_PID_FILE" "$pid"
    echo "daemon already running (pid $pid, adopted)"
    return 0
  fi
  setsid env WORKSPACE="$SHADOW" BRAIN_WORKSPACE="$SHADOW" OPENCLAW_WORKSPACE="$SHADOW" \
    bash "$SHADOW/brain-daemon.sh" >> "$DAEMON_LOG" 2>&1 < /dev/null &
  sleep 2
  pid=$(pgrep -f "workspace-shadow/brain-daemon.sh" | head -1 || true)
  if [ -n "$pid" ]; then
    write_pidfile "$DAEMON_PID_FILE" "$pid"
    echo "[$(ts)] daemon started (pid $pid) boot=$BOOT" >> "$LOG_DIR/supervisor.log"
    echo "daemon started (pid $pid)"
  else
    echo "[$(ts)] daemon FAILED to start boot=$BOOT — see $DAEMON_LOG" >> "$LOG_DIR/supervisor.log"
    echo "daemon FAILED to start — see $DAEMON_LOG" >&2
    return 1
  fi
}

start_keeper() {
  local pid
  if pid=$(alive "$KEEPER_PID_FILE" "helm-keeper-shadow"); then
    echo "keeper already running (pid $pid)"
    return 0
  fi
  # Adopt before launch — see start_daemon (2026-11-09 Phase 3b defect).
  pid=$(pgrep -f "helm-keeper-shadow" | head -1 || true)
  if [ -n "$pid" ]; then
    write_pidfile "$KEEPER_PID_FILE" "$pid"
    echo "keeper already running (pid $pid, adopted)"
    return 0
  fi
  setsid env WORKSPACE="$SHADOW" BRAIN_WORKSPACE="$SHADOW" OPENCLAW_WORKSPACE="$SHADOW" \
    python3 "$HOME/.juno-brain/bin/helm-keeper-shadow" >> "$KEEPER_LOG" 2>&1 < /dev/null &
  sleep 2
  pid=$(pgrep -f "helm-keeper-shadow" | head -1 || true)
  if [ -n "$pid" ]; then
    write_pidfile "$KEEPER_PID_FILE" "$pid"
    echo "[$(ts)] keeper started (pid $pid) boot=$BOOT" >> "$LOG_DIR/supervisor.log"
    echo "keeper started (pid $pid)"
  else
    echo "[$(ts)] keeper FAILED to start boot=$BOOT — see $KEEPER_LOG" >> "$LOG_DIR/supervisor.log"
    echo "keeper FAILED to start — see $KEEPER_LOG" >&2
    return 1
  fi
}

stop_one() { # stop_one <pidfile> <name> <cmdline-marker>
  local f="$1" name="$2" marker="$3" pid
  if pid=$(alive "$f" "$marker"); then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    echo "[$(ts)] $name stopped (pid $pid) boot=$BOOT" >> "$LOG_DIR/supervisor.log"
    echo "$name stopped (pid $pid)"
  else
    echo "$name not running"
  fi
  rm -f "$f"
}

case "${1:-}" in
  start-daemon) start_daemon ;;
  start-keeper) start_keeper ;;
  start) start_daemon; start_keeper ;;
  stop) stop_one "$DAEMON_PID_FILE" daemon "workspace-shadow/brain-daemon.sh"; stop_one "$KEEPER_PID_FILE" keeper "helm-keeper-shadow" ;;
  status)
    if pid=$(alive "$DAEMON_PID_FILE" "workspace-shadow/brain-daemon.sh"); then echo "daemon: running (pid $pid)"; else echo "daemon: NOT RUNNING"; fi
    if pid=$(alive "$KEEPER_PID_FILE" "helm-keeper-shadow"); then echo "keeper: running (pid $pid)"; else echo "keeper: NOT RUNNING"; fi
    ;;
  *) echo "usage: $0 start|start-daemon|start-keeper|stop|status" >&2; exit 2 ;;
esac
