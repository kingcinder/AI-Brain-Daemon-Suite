#!/bin/bash
# rwlock.sh — Reader-writer lock with non-blocking reads for the primary loop.
#
# Phase 1b safety rail (Immutable Core once landed).
#
# Semantics:
#   - Multiple concurrent readers allowed.
#   - Writers take exclusive access; write-lock held from check until apply/reject.
#   - Readers use non-blocking try-read: if a writer holds the lock, return
#     status 2 so the primary loop can use last-known-good snapshot.
#   - Stale-lock timeout: if a write lock holder is dead past stale_sec, reclaim.
#
# Layout under <lock-dir>:
#   write.lock     — exclusive flock for writers
#   readers.count  — integer reader count (updated under meta.lock)
#   meta.lock      — flock protecting readers.count
#   writer.pid     — writer PID while write-locked
#   writer.starttime
#   writer.heartbeat
#
# Usage (source or CLI):
#   rwlock_try_read_acquire <lock-dir>     # 0 ok, 2 writer active / busy
#   rwlock_read_release <lock-dir>
#   rwlock_write_acquire <lock-dir> [stale-sec] [timeout-sec]
#   rwlock_write_heartbeat <lock-dir>
#   rwlock_write_release <lock-dir>

set -euo pipefail

_rwlock_starttime() {
  local pid="$1"
  if [ -r "/proc/$pid/stat" ]; then
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

_rwlock_writer_live() {
  local lock_dir="$1" stale_sec="${2:-120}"
  local pid_path="$lock_dir/writer.pid"
  local st_path="$lock_dir/writer.starttime"
  local hb_path="$lock_dir/writer.heartbeat"
  [ -f "$pid_path" ] || return 1
  local pid st
  pid=$(cat "$pid_path" 2>/dev/null || true)
  st=$(cat "$st_path" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  local actual
  actual=$(_rwlock_starttime "$pid")
  if [ -n "$st" ] && [ -n "$actual" ] && [ "$st" != "$actual" ]; then
    return 1
  fi
  if [ -f "$hb_path" ]; then
    local last now age
    last=$(cat "$hb_path" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - last))
    [ "$age" -le "$stale_sec" ] || return 1
  fi
  return 0
}

_rwlock_reclaim_stale_writer() {
  local lock_dir="$1" stale_sec="$2"
  if _rwlock_writer_live "$lock_dir" "$stale_sec"; then
    return 1
  fi
  rm -f "$lock_dir/writer.pid" "$lock_dir/writer.starttime" "$lock_dir/writer.heartbeat" 2>/dev/null || true
  return 0
}

rwlock_try_read_acquire() {
  local lock_dir="${1:?lock-dir required}"
  mkdir -p "$lock_dir"
  local write_lock="$lock_dir/write.lock"
  local meta_lock="$lock_dir/meta.lock"
  touch "$write_lock" "$meta_lock" 2>/dev/null || true

  # Non-blocking: if write lock is held, primary loop uses last-known-good
  exec 210>"$write_lock"
  if ! flock -n -s 210; then
    exec 210>&-
    return 2
  fi

  exec 211>"$meta_lock"
  flock -x 211
  local count=0
  if [ -f "$lock_dir/readers.count" ]; then
    count=$(cat "$lock_dir/readers.count" 2>/dev/null || echo 0)
  fi
  echo $((count + 1)) > "$lock_dir/readers.count"
  flock -u 211
  exec 211>&-
  # Keep shared write.lock flock held for duration of read (fd 210)
  return 0
}

rwlock_read_release() {
  local lock_dir="${1:?lock-dir required}"
  local meta_lock="$lock_dir/meta.lock"
  touch "$meta_lock" 2>/dev/null || true
  exec 211>"$meta_lock"
  flock -x 211
  local count=0
  if [ -f "$lock_dir/readers.count" ]; then
    count=$(cat "$lock_dir/readers.count" 2>/dev/null || echo 0)
  fi
  if [ "$count" -gt 0 ]; then
    echo $((count - 1)) > "$lock_dir/readers.count"
  else
    echo 0 > "$lock_dir/readers.count"
  fi
  flock -u 211
  exec 211>&-
  exec 210>&- 2>/dev/null || true
  return 0
}

rwlock_write_acquire() {
  local lock_dir="${1:?lock-dir required}"
  local stale_sec="${2:-120}"
  local timeout_sec="${3:-15}"
  mkdir -p "$lock_dir"
  local write_lock="$lock_dir/write.lock"
  touch "$write_lock" 2>/dev/null || true

  _rwlock_reclaim_stale_writer "$lock_dir" "$stale_sec" || true

  exec 220>"$write_lock"
  if ! flock -x -w "$timeout_sec" 220; then
    if _rwlock_reclaim_stale_writer "$lock_dir" "$stale_sec"; then
      if ! flock -x -w 2 220; then
        echo "rwlock: write acquire failed after stale reclaim" >&2
        exec 220>&-
        return 1
      fi
    else
      echo "rwlock: write acquire timeout (${timeout_sec}s)" >&2
      exec 220>&-
      return 1
    fi
  fi

  local my_pid=$$
  echo "$my_pid" > "$lock_dir/writer.pid"
  _rwlock_starttime "$my_pid" > "$lock_dir/writer.starttime"
  date +%s > "$lock_dir/writer.heartbeat"
  return 0
}

rwlock_write_heartbeat() {
  local lock_dir="${1:?lock-dir required}"
  date +%s > "$lock_dir/writer.heartbeat"
}

rwlock_write_release() {
  local lock_dir="${1:?lock-dir required}"
  rm -f "$lock_dir/writer.pid" "$lock_dir/writer.starttime" "$lock_dir/writer.heartbeat" 2>/dev/null || true
  exec 220>&- 2>/dev/null || true
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    try-read)     rwlock_try_read_acquire "$@" ;;
    read-release) rwlock_read_release "$@" ;;
    write-acquire) rwlock_write_acquire "$@" ;;
    write-heartbeat) rwlock_write_heartbeat "$@" ;;
    write-release) rwlock_write_release "$@" ;;
    *)
      echo "Usage: $0 {try-read|read-release|write-acquire|write-heartbeat|write-release} <lock-dir> ..." >&2
      exit 2
      ;;
  esac
fi
