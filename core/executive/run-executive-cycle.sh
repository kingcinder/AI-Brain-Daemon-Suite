#!/bin/bash
# run-executive-cycle.sh — Phase 2 executive function cycle for the daemon.
#
# Pipeline:
#   1. isolated-reflect (read-only isolation; no live state writes)
#   2. propose-goals (queue proposals; optionally promote under caps)
#
# Default: --promote (safe caps inside propose-goals; skipped if E >= 0.75).
# Pass --no-promote to only queue proposals.
#
# Usage:
#   run-executive-cycle.sh [--workspace PATH] [--no-promote] [--dry-run]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
PROMOTE=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --no-promote) PROMOTE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--workspace PATH] [--no-promote] [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

export WORKSPACE
mkdir -p "$WORKSPACE/memory/executive"

# ── Closed-loop: hippocampus consolidation → PFC reflection ───────────────
# The consolidate.sh script drops a .pending-reflection marker after weekly
# memory consolidation. When present, run a targeted reflection that pulls
# in the freshly consolidated memory store so PFC goals can adapt to what
# changed in long-term memory.
PENDING_REFLECTION="$WORKSPACE/memory/.pending-reflection"
if [ -f "$PENDING_REFLECTION" ]; then
    echo "executive-cycle: hippocampus consolidation detected — triggering targeted reflection..."
    # Run a reflection with extra context: pass consolidated memory dirs as
    # additional snapshot sources. isolate-reflect.sh is read-only, so this
    # just enriches its signal set — no mutation risk.
    if [ -x "$ROOT/core/executive/isolated-reflect.sh" ]; then
        HIPPO_REF=$(bash "$ROOT/core/executive/isolated-reflect.sh" --workspace "$WORKSPACE" --out "$WORKSPACE/memory/executive/reflections")
        echo "executive-cycle: post-consolidation reflection -> $HIPPO_REF"
    fi
    # Clear the marker so we don't re-trigger until next consolidation
    rm -f "$PENDING_REFLECTION"
    # The post-consolidation reflection may have produced goal proposals
    # (like "review what changed in long-term memory"). Let propose-goals
    # pick them up in its normal pass below.
fi

echo "executive-cycle: isolated reflection..."
REF=$(bash "$ROOT/core/executive/isolated-reflect.sh" --workspace "$WORKSPACE")
echo "executive-cycle: reflection -> $REF"

ARGS=(--workspace "$WORKSPACE" --reflection "$REF")
if [ "$PROMOTE" -eq 1 ]; then
  ARGS+=(--promote)
fi
if [ "$DRY_RUN" -eq 1 ]; then
  ARGS+=(--dry-run)
fi

echo "executive-cycle: propose-goals ${ARGS[*]}..."
bash "$ROOT/core/executive/propose-goals.sh" "${ARGS[@]}"

# Cycle marker for monitoring / load diagnostics
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -nc --arg ts "$TS" --arg ref "$REF" \
  '{last_cycle_utc:$ts, last_reflection:$ref, phase:"2"}' \
  > "$WORKSPACE/memory/executive/last-cycle.json"

echo "executive-cycle: complete ($TS)"
exit 0
