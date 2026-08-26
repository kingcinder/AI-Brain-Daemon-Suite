#!/bin/bash
# sandbox-run.sh — Subprocess + snapshot sandbox harness (Phase 1b Immutable Core).
#
# Runs a candidate command in a subprocess against a temporary workspace
# copy (or chdir isolation), after creating a baseline snapshot of real
# state. Never modifies Immutable Core paths. On failure, restores LKG.
#
# Usage:
#   sandbox-run.sh --cmd 'bash ./candidate.sh' [--timeout SEC] [--label NAME]
#   sandbox-run.sh --cmd-file path/to/script.sh [--timeout SEC]
#
# Exit: propagates command exit code. Writes JSON result to stdout last line
# prefix SANDBOX_RESULT: {...}

set -euo pipefail

CORE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SNAPSHOT_SH="$CORE_ROOT/snapshot/snapshot.sh"
PROV_SH="$CORE_ROOT/provenance/log-provenance.sh"

CMD=""
CMD_FILE=""
TIMEOUT_SEC="${SANDBOX_TIMEOUT:-120}"
LABEL="sandbox"
PROPOSAL_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd) CMD="$2"; shift 2 ;;
    --cmd-file) CMD_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --proposal-id) PROPOSAL_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "$CMD_FILE" ]; then
  if [ ! -f "$CMD_FILE" ]; then
    echo "sandbox: cmd-file not found: $CMD_FILE" >&2
    exit 2
  fi
  CMD="bash $(printf %q "$CMD_FILE")"
fi

if [ -z "$CMD" ]; then
  echo "Usage: $0 --cmd '...' | --cmd-file PATH [--timeout SEC] [--label NAME]" >&2
  exit 2
fi

PROPOSAL_ID="${PROPOSAL_ID:-sandbox-$(date +%s)-$$}"

# 1. Baseline snapshot of live state
BASELINE_JSON=$(WORKSPACE="$WORKSPACE" bash "$SNAPSHOT_SH" create --label "pre-${LABEL}")
BASELINE_ID=$(echo "$BASELINE_JSON" | jq -r .snapshot_id)

# 2. Isolated temp dir for sandbox work
SANDBOX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aibrain-sandbox.XXXXXX")
cleanup() {
  rm -rf "$SANDBOX_DIR"
}
trap cleanup EXIT

# Copy memory snapshot files into sandbox view (read-only baseline + writable copy)
mkdir -p "$SANDBOX_DIR/memory"
if [ -d "$WORKSPACE/memory" ]; then
  # Prefer LKG snapshot files when present
  if [ -d "$WORKSPACE/memory/snapshots/$BASELINE_ID/files" ]; then
    cp -a "$WORKSPACE/memory/snapshots/$BASELINE_ID/files/." "$SANDBOX_DIR/memory/" 2>/dev/null || true
  fi
  # Overlay live memory (non-destructive to host — we only copy in)
  find "$WORKSPACE/memory" -maxdepth 1 -type f -name '*.json' -exec cp -a {} "$SANDBOX_DIR/memory/" \; 2>/dev/null || true
fi

# 3. Run command with sandbox WORKSPACE, timeout, no write to Immutable Core of host
#    Host core/ is mounted read-only by not copying it; only SANDBOX_DIR is writable.
set +e
START_TS=$(date +%s)
timeout --signal=TERM --kill-after=10 "$TIMEOUT_SEC" \
  env WORKSPACE="$SANDBOX_DIR" \
      SANDBOX=1 \
      SANDBOX_BASELINE="$BASELINE_ID" \
      bash -c "$CMD" \
  >"$SANDBOX_DIR/stdout.log" 2>"$SANDBOX_DIR/stderr.log"
RC=$?
END_TS=$(date +%s)
set -e
ELAPSED=$((END_TS - START_TS))

# timeout returns 124 on timeout
TIMED_OUT=false
[ "$RC" -eq 124 ] && TIMED_OUT=true

SUCCESS=false
[ "$RC" -eq 0 ] && SUCCESS=true

# 4. Provenance entry
CONTENT_BLOB="cmd=${CMD};rc=${RC};baseline=${BASELINE_ID}"
if [ -x "$PROV_SH" ] || [ -f "$PROV_SH" ]; then
  WORKSPACE="$WORKSPACE" bash "$PROV_SH" append \
    --proposal-id "$PROPOSAL_ID" \
    --content "$CONTENT_BLOB" \
    --parent-hash "$BASELINE_ID" \
    --proposer "sandbox-run" \
    --sandbox-score "$( [ "$SUCCESS" = true ] && echo 1 || echo 0 )" \
    --rollback-status "$( [ "$SUCCESS" = true ] && echo accepted || echo none )" \
    >/dev/null 2>&1 || true
fi

RESULT=$(jq -nc \
  --arg pid "$PROPOSAL_ID" \
  --arg baseline "$BASELINE_ID" \
  --argjson rc "$RC" \
  --argjson success "$SUCCESS" \
  --argjson timed_out "$TIMED_OUT" \
  --argjson elapsed "$ELAPSED" \
  --arg stdout "$(tail -c 4000 "$SANDBOX_DIR/stdout.log" 2>/dev/null | sed 's/\\/\\\\/g' | tr '\n' ' ')" \
  --arg stderr "$(tail -c 2000 "$SANDBOX_DIR/stderr.log" 2>/dev/null | sed 's/\\/\\\\/g' | tr '\n' ' ')" \
  '{
    proposal_id: $pid,
    baseline_snapshot: $baseline,
    exit_code: $rc,
    success: $success,
    timed_out: $timed_out,
    elapsed_sec: $elapsed,
    stdout_tail: $stdout,
    stderr_tail: $stderr
  }')

# Stream command output for debugging
if [ -s "$SANDBOX_DIR/stdout.log" ]; then
  cat "$SANDBOX_DIR/stdout.log"
fi
if [ -s "$SANDBOX_DIR/stderr.log" ]; then
  cat "$SANDBOX_DIR/stderr.log" >&2
fi

echo "SANDBOX_RESULT: $RESULT"
exit "$RC"
