#!/bin/bash
# pid-lock.sh — Single-instance PID lock with starttime + heartbeat staleness.
#
# Phase 1a foundation. Crash recovery: if the lock holder is dead, or the
# PID was reused (starttime mismatch), or the heartbeat is stale, reclaim.
#
# Usage:
#   source pid-lock.sh
#   pid_lock_acquire <lock-dir> [heartbeat-stale-sec]   # default 90s
#   pid_lock_heartbeat <lock-dir>                       # refresh heartbeat
#   pid_lock_release <lock-dir>
#
# Lock dir layout:
#   <lock-dir>/pid          — holder PID
#   <lock-dir>/starttime    — /proc/<pid>/stat field 22 at acquire
#   <lock-dir>/heartbeat    — unix epoch seconds of last heartbeat
#   <lock-dir>/holder.lock  — flock exclusive while holding (auto-release on death)

set -euo pipefail

_pid_lock_starttime() {
  local pid="$1"
  # field 22 of /proc/<pid>/stat (1-indexed) is starttime in clock ticks
  if [ -r "/proc/$pid/stat" ]; then
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

_pid_lock_alive() {
  local pid="$1" expected_st="$2"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  local actual_st
  actual_st=$(_pid_lock_starttime "$pid")
  if [ -z "$actual_st" ] || [ -z "$expected_st" ]; then
    # Can't verify starttime — treat as alive only if process exists
    return 0
  fi
  [ "$actual_st" = "$expected_st" ]
}

_pid_lock_heartbeat_fresh() {
  local hb_file="$1" stale_sec="$2"
  if [ ! -f "$hb_file" ]; then
    return 1
  fi
  local last now age
  last=$(cat "$hb_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - last))
  [ "$age" -le "$stale_sec" ]
}

pid_lock_acquire() {
  local lock_dir="${1:?lock-dir required}"
  local stale_sec="${2:-90}"
  mkdir -p "$lock_dir"
  local flock_path="$lock_dir/holder.lock"
  local pid_path="$lock_dir/pid"
  local st_path="$lock_dir/starttime"
  local hb_path="$lock_dir/heartbeat"

  # fd 201 dedicated to this lock for the process lifetime of the holder script
  exec 201>"$flock_path"
  if ! flock -n 201; then
    # Someone holds flock — check if it's a live legitimate holder
    local existing_pid existing_st
    existing_pid=$(cat "$pid_path" 2>/dev/null || true)
    existing_st=$(cat "$st_path" 2>/dev/null || true)
    if _pid_lock_alive "$existing_pid" "$existing_st" && _pid_lock_heartbeat_fresh "$hb_path" "$stale_sec"; then
      echo "pid-lock: already held by live pid $existing_pid" >&2
      exec 201>&-
      return 1
    fi
    # Stale: wait briefly for flock (holder may be dying) then force reclaim path
    if ! flock -w 2 201; then
      echo "pid-lock: could not acquire flock (stuck holder?)" >&2
      exec 201>&-
      return 1
    fi
  fi

  local my_pid=$$
  local my_st
  my_st=$(_pid_lock_starttime "$my_pid")
  echo "$my_pid" > "$pid_path"
  echo "$my_st" > "$st_path"
  date +%s > "$hb_path"
  return 0
}

pid_lock_heartbeat() {
  local lock_dir="${1:?lock-dir required}"
  date +%s > "$lock_dir/heartbeat"
}

pid_lock_release() {
  local lock_dir="${1:?lock-dir required}"
  rm -f "$lock_dir/pid" "$lock_dir/starttime" "$lock_dir/heartbeat" 2>/dev/null || true
  # Closing fd releases flock
  exec 201>&- 2>/dev/null || true
}

# CLI mode when executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    acquire)  pid_lock_acquire "$@" ;;
    heartbeat) pid_lock_heartbeat "$@" ;;
    release)  pid_lock_release "$@" ;;
    *)
      echo "Usage: $0 {acquire|heartbeat|release} <lock-dir> [stale-sec]" >&2
      exit 2
      ;;
  esac
fi
