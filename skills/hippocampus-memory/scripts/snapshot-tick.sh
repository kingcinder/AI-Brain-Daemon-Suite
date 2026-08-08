#!/bin/bash
# snapshot-tick.sh — Daemon entry: daily brain-state preservation snapshot.
#
# Memory must be recoverable: this runs core/snapshot/snapshot.sh create once a
# day (JOBS table: brain_snapshot, 23:03 UTC, direct) against every JSON state
# file in $WORKSPACE/memory, so the brain's memory + executive + decision state
# has a last-known-good restore point that predates any bad day — the same
# snapshot machinery the self-mod pipeline uses for baseline divergence.
#
# The divergence-check defaults (pfc-state, executive-load, decision-queue) are
# always included even when they don't exist yet (snapshot.sh records "missing"
# hashes rather than failing). Retention: the most recent SNAPSHOT_KEEP (14)
# snapshots are kept; older ones are pruned so the store can't grow unbounded.
#
# Usage:
#   snapshot-tick.sh            # snapshot everything + prune
#   snapshot-tick.sh --keep N   # override retention (default 14)
#
# Env:
#   WORKSPACE        Defaults to $HOME/.hermes/workspace
#   SNAPSHOT_KEEP    Retention count (default 14)
#
# Exit code: 0 on success, 1 if the snapshot itself fails (a prune hiccup is
# non-fatal — the daemon records a success only if the snapshot landed).

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEEP="${SNAPSHOT_KEEP:-14}"
# Honor SNAPSHOT_ROOT exactly like snapshot.sh does, so the ledger + prune
# always target the same root the snapshots are actually written to.
SNAP_ROOT="${SNAPSHOT_ROOT:-$WORKSPACE/memory/snapshots}"

# Resolve the snapshot engine from the deployed workspace or the repo, exactly
# like monitor-tick.sh / proposal-cycle-tick.sh do for their core targets.
if [ -x "$WORKSPACE/core/snapshot/snapshot.sh" ]; then
    SNAP="$WORKSPACE/core/snapshot/snapshot.sh"
elif [ -x "$SCRIPT_DIR/../../../core/snapshot/snapshot.sh" ]; then
    SUITE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    SNAP="$SUITE_ROOT/core/snapshot/snapshot.sh"
else
    echo "snapshot-tick: core/snapshot/snapshot.sh not found" >&2
    exit 1
fi

mkdir -p "$WORKSPACE/memory"

# ── 1. Build the file list: every memory JSON state file + divergence defaults ──
STATE_FILES=()
for f in "$WORKSPACE"/memory/*.json; do
    [ -f "$f" ] && STATE_FILES+=("$f")
done
# Always include the divergence-check trio even if absent (recorded as missing).
STATE_FILES+=(
    "$WORKSPACE/memory/pfc-state.json"
    "$WORKSPACE/memory/executive-load.json"
    "$WORKSPACE/memory/decision-queue.json"
)

# Dedupe while preserving order, then CSV-join (snapshot.sh takes --files CSV).
DEDUPED=()
declare -A SEEN
for f in "${STATE_FILES[@]}"; do
    if [ -z "${SEEN[$f]+_}" ]; then
        SEEN["$f"]=1
        DEDUPED+=("$f")
    fi
done
FILES_CSV=$(printf '%s,' "${DEDUPED[@]}" | sed 's/,$//')

# ── 2. Create the snapshot ──────────────────────────────────────────────────
SNAP_OUT=$(WORKSPACE="$WORKSPACE" SNAPSHOT_ROOT="$SNAP_ROOT" bash "$SNAP" create --label daily --files "$FILES_CSV" 2>&1) || {
    echo "snapshot-tick: snapshot create failed: $SNAP_OUT" >&2
    exit 1
}
SNAP_ID=$(printf '%s' "$SNAP_OUT" | jq -r '.snapshot_id // empty')
[ -n "$SNAP_ID" ] || {
    echo "snapshot-tick: snapshot create returned no id: $SNAP_OUT" >&2
    exit 1
}

# ── 3. Append a one-line ledger for observability ───────────────────────────
LEDGER="$SNAP_ROOT/index.jsonl"
mkdir -p "$SNAP_ROOT"
printf '%s\n' "$(printf '%s' "$SNAP_OUT" | jq -c '{snapshot_id, created_at, files: (.files|length), executive_load, goals_hash, inhibitions_hash}')" >> "$LEDGER"

# ── 4. Prune to the most recent KEEP snapshots (non-fatal) ─────────────────
if [ "${KEEP:-14}" -gt 0 ]; then
    OLD=$(ls -1t "$SNAP_ROOT" 2>/dev/null | grep -v '^index.jsonl$' | grep -v '^last-known-good$' | tail -n +$((KEEP + 1)))
    if [ -n "$OLD" ]; then
        for d in $OLD; do
            rm -rf "$SNAP_ROOT/$d" 2>/dev/null || true
        done
    fi
fi

echo "snapshot-tick: brain snapshot $SNAP_ID saved ($(printf '%s' "$SNAP_OUT" | jq -r '.files|length') files, keep=$KEEP)"
exit 0
