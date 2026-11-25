#!/bin/bash
# lease.sh — Gate lease for singleton producers (Gated-Ingress Refactor,
# invariant I7, 2026-11-20).
#
# A singleton producer (brain-daemon, helm-keeper) registers a lease at
# startup. If a LIVE leaseholder already exists, the second starter is
# REFUSED (exit 7) and the refusal is logged to the ACC error ledger —
# uniqueness by prevention, not just patrol detection. This is the
# mechanism that makes the 2026-11-20 duplicate-daemon incident
# (systemd pair + hand-started pair running ~1h47m in parallel)
# structurally impossible for any producer that starts through this path.
#
# A lease is stale — and may be taken over — when its pid is dead, or
# the pid was recycled (process start-time or boot id mismatch).
#
# Usage:
#   lease.sh acquire --name NAME --pid PID
#   lease.sh release --name NAME --pid PID
#   lease.sh status  --name NAME
#
# Leases live in $WORKSPACE/memory/gate-leases/<name>.json
# Exit: 0 ok · 2 usage · 7 refused (live holder)

set -euo pipefail

WORKSPACE="${WORKSPACE:-${BRAIN_WORKSPACE:-$HOME/.juno-brain/workspace}}"
LEASE_DIR="$WORKSPACE/memory/gate-leases"
mkdir -p "$LEASE_DIR"

ACTION="${1:-}"; shift || true
NAME=""; PID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --pid)  PID="$2";  shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$NAME" ]] || { echo "lease.sh: --name required" >&2; exit 2; }
LEASE="$LEASE_DIR/$NAME.json"
LOCK="$LEASE_DIR/.leases.lock"

boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown"; }
start_time() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo ""; }

holder_live() {
  # $1 = lease file. Returns 0 if the recorded holder is genuinely alive.
  [[ -f "$1" ]] || return 1
  local hpid hstart hboot
  hpid=$(jq -r '.pid // empty' "$1" 2>/dev/null) || return 1
  [[ -n "$hpid" ]] || return 1
  kill -0 "$hpid" 2>/dev/null || return 1
  hstart=$(jq -r '.proc_start // empty' "$1" 2>/dev/null || echo "")
  hboot=$(jq -r '.boot_id // empty' "$1" 2>/dev/null || echo "")
  [[ "$hboot" = "$(boot_id)" ]] || return 1
  [[ -z "$hstart" || "$hstart" = "$(start_time "$hpid")" ]] || return 1
  return 0
}

exec 201>"$LOCK"
flock 201

case "$ACTION" in
  acquire)
    [[ -n "$PID" ]] || { echo "lease.sh: --pid required" >&2; exit 2; }
    if holder_live "$LEASE"; then
      HPID=$(jq -r '.pid' "$LEASE")
      echo "lease refused: '$NAME' already held by live pid $HPID" >&2
      # Log the refusal to the ACC error ledger (best-effort).
      ACC_LOG="$WORKSPACE/skills/acc-error-memory/scripts/log-error.sh"
      if [[ -x "$ACC_LOG" ]]; then
        WORKSPACE="$WORKSPACE" bash "$ACC_LOG" \
          --pattern "duplicate-singleton-refused" \
          --context "gate lease refused a second '$NAME' (live holder pid $HPID, refused pid $PID)" \
          --mitigation "singleton producers start only via their systemd unit; the gate lease refuses duplicates" >/dev/null 2>&1 || true
      fi
      exit 7
    fi
    jq -nc --arg name "$NAME" --argjson pid "$PID" \
       --arg start "$(start_time "$PID")" --arg boot "$(boot_id)" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '{name:$name, pid:$pid, proc_start:$start, boot_id:$boot, acquired_at:$ts}' \
       > "$LEASE.tmp.$$" && mv "$LEASE.tmp.$$" "$LEASE"
    echo "lease acquired: $NAME pid $PID"
    ;;
  release)
    if [[ -f "$LEASE" ]] && [[ "$(jq -r '.pid // empty' "$LEASE" 2>/dev/null)" = "$PID" ]]; then
      rm -f "$LEASE"
      echo "lease released: $NAME"
    else
      echo "lease not held by pid $PID (no-op)"
    fi
    ;;
  status)
    if holder_live "$LEASE"; then
      cat "$LEASE"
    else
      echo "{\"name\":\"$NAME\",\"held\":false}"
    fi
    ;;
  *)
    echo "Usage: $0 {acquire|release|status} --name NAME [--pid PID]" >&2
    exit 2
    ;;
esac
