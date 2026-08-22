#!/bin/bash
# safe-write.sh — flock-guarded wrapper for state-file read-modify-write cycles.
#
# THE PROBLEM:
# Every script in the brain suite mutates its state file via the same pattern:
#   <command> "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
# With no locking, two processes touching the same file concurrently (e.g. a
# cron'd decay job firing while a manual update script is mid-write) can race:
# both read the old version, both compute against it, and whichever mv lands
# last silently overwrites the other's update (a classic lost-update race).
# If two processes ever land on the same .tmp filename at the same instant,
# the file on disk during that window is undefined.
#
# THE FIX:
# Serialize the whole read-modify-write cycle per state file using flock on a
# sibling .lock file. This does NOT require rewriting any module's jq/python
# mutation logic — it only changes how that logic is invoked.
#
# USAGE:
#   safe-write.sh <state-file> <command> [args...]
#
# <command> [args...] runs with the lock held and with STATE_FILE exported
# into its environment. It should do exactly what it already does today
# (read -> compute -> write to .tmp -> mv into place) — safe-write.sh doesn't
# know or care what the mutation is, it only guarantees that no two such
# cycles run concurrently against the same state file.
#
# EXAMPLE — drop-in migration of an existing line:
#   Before:
#     jq '.foo = 1' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
#   After (write the mutation to a small script file, then):
#     "$SCRIPT_DIR/safe-write.sh" "$STATE_FILE" "$MUTATE_SCRIPT"
#   Avoid inlining the mutation as a `bash -c '...'` one-liner passed as an
#   argument — nested single/double-quote escaping across two shell parses
#   (this script's, then bash -c's) is easy to get subtly wrong. A temp
#   script file has exactly one layer of quoting to get right.
#
# Lock files live next to the state file as <state-file>.lock. They are
# never deleted — a persistent zero-byte lock file is the normal, correct
# way to use flock, not a leak.

set -euo pipefail

STATE_FILE="$1"
shift || true

if [ -z "$STATE_FILE" ] || [ "$#" -eq 0 ]; then
  echo "Usage: safe-write.sh <state-file> <command> [args...]" >&2
  exit 1
fi

LOCK_FILE="${STATE_FILE}.lock"

# Ensure the lock file exists before opening an fd on it.
touch "$LOCK_FILE" 2>/dev/null || true

# Dedicated fd (200) for the lock, held for the wrapped command's duration.
# flock releases automatically when this fd closes — i.e. when this script
# exits for any reason, including the wrapped command failing or this
# process being killed. No stale locks survive process death.
exec 200>"$LOCK_FILE"

if ! flock -x -w 15 200; then
  echo "❌ Could not acquire lock on $LOCK_FILE within 15s — another process may be stuck holding it." >&2
  exit 1
fi

export STATE_FILE

# Explicit set +e/-e around the call: under set -e (top of this file), if
# "$@" failed and this were left as a bare call, bash would exit
# immediately with that command's status the instant it failed — making
# STATUS=$?/exit $STATUS below unreachable dead code. The exit code was
# still correct either way (errexit propagates it), but the dead code was
# misleading to read. This makes the capture actually happen as written.
set +e
"$@"
STATUS=$?
set -euo pipefail

exit $STATUS
