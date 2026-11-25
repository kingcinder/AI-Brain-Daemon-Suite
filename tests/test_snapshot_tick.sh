#!/bin/bash
# Unit: snapshot-tick.sh preserves brain state as a daily restore point.
# Asserts: snapshot lands under memory/snapshots, last-known-good pointer
# updates, seeded state files are copied, a ledger line is appended, and a
# second run creates a NEW snapshot (idempotence without collapse).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"

# Seed the divergence-check trio the tick must preserve.
echo '{"goals":[{"id":"g1","status":"active","description":"test goal"}]}' > "$WORKSPACE/memory/pfc-state.json"
echo '{"E":0.42}' > "$WORKSPACE/memory/executive-load.json"
echo '{"pending":[]}' > "$WORKSPACE/memory/decision-queue.json"

OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/hippocampus-memory/scripts/snapshot-tick.sh")
[[ "$OUT" == *'brain snapshot'* ]] || { echo "FAIL: no snapshot success line"; exit 1; }
[[ "$OUT" == *'files'* ]] || { echo "FAIL: no file count in output"; exit 1; }

SNAP_ROOT="$WORKSPACE/memory/snapshots"
[ -f "$SNAP_ROOT/last-known-good" ] || { echo "FAIL: no last-known-good pointer"; exit 1; }
SID=$(cat "$SNAP_ROOT/last-known-good")
[ -n "$SID" ] || { echo "FAIL: empty snapshot id"; exit 1; }
[ -f "$SNAP_ROOT/$SID/meta.json" ] || { echo "FAIL: snapshot meta.json missing"; exit 1; }
[ -f "$SNAP_ROOT/$SID/files/pfc-state.json" ] || { echo "FAIL: pfc-state not snapshotted"; exit 1; }
[ -f "$SNAP_ROOT/$SID/files/executive-load.json" ] || { echo "FAIL: executive-load not snapshotted"; exit 1; }
[ -f "$SNAP_ROOT/$SID/files/decision-queue.json" ] || { echo "FAIL: decision-queue not snapshotted"; exit 1; }
grep -q "$SID" "$SNAP_ROOT/index.jsonl" || { echo "FAIL: no ledger entry for snapshot"; exit 1; }
jq -e --arg sid "$SID" '.snapshot_id==$sid' "$SNAP_ROOT/$SID/meta.json" >/dev/null \
  || { echo "FAIL: meta.json snapshot_id mismatch"; exit 1; }
jq -e '.files | length == 3' "$SNAP_ROOT/$SID/meta.json" >/dev/null \
  || { echo "FAIL: expected 3 files snapshotted"; exit 1; }

# Second run must produce a NEW snapshot (fresh id), not reuse the first.
OUT2=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/hippocampus-memory/scripts/snapshot-tick.sh")
[[ "$OUT2" == *'brain snapshot'* ]] || { echo "FAIL: second run failed"; exit 1; }
SID2=$(cat "$SNAP_ROOT/last-known-good")
[ "$SID" != "$SID2" ] || { echo "FAIL: second run reused snapshot id"; exit 1; }

echo "PASS: snapshot-tick"
