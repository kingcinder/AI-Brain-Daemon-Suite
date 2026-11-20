#!/bin/bash
# Glymphatic clearance sweep — the organ's pipeline.
# Audits backlog age in registered queue stores, archives old dead
# letters, reaps stale gate leases, reports orphan stores. Every
# action is ledgered with provenance; conservation identity printed.
# Usage: clearance-sweep.sh [--no-spawn]   (flag accepted, ignored —
# the sweep never spawns; it is a single deterministic pass)
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
export WORKSPACE
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/clearance-sweep.py"
# Sync the state face after each sweep
WORKSPACE="$WORKSPACE" "$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
