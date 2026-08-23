#!/bin/bash
# Unit: Hippocampus consolidation replays episodic traces into cortical
# themes (CLS episodic→semantic transfer via offline replay; Buzsáki) —
# asserts consolidation actually happens on a synthetic dataset, not just
# that the script runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/index.json" << 'EOF'
{"memories":[
  {"id":"mem_001","content":"user prefers dark mode","domain":"user","category":"preferences","created":"2026-08-22","lastAccessed":"2026-08-23"},
  {"id":"mem_002","content":"deadline friday","domain":"user","category":"context","created":"2026-08-21","lastAccessed":"2026-08-22"},
  {"id":"mem_003","content":"shipping feature x","domain":"world","category":"projects","created":"2026-08-22","lastAccessed":"2026-08-23"}
]}
EOF

WORKSPACE="$WORKSPACE" bash "$ROOT/skills/hippocampus-memory/scripts/consolidate.sh" >/dev/null 2>&1

# cortical.json exists with themes + one replay event per replayed trace
[ -f "$WORKSPACE/memory/cortical.json" ]
jq -e '.themes | keys | length == 3' "$WORKSPACE/memory/cortical.json" >/dev/null
jq -e '.themes["user/preferences"].weight == 0.1' "$WORKSPACE/memory/cortical.json" >/dev/null
jq -e '.replays | length == 3' "$WORKSPACE/memory/cortical.json" >/dev/null

# Second pass accumulates weight — slow cortical strengthening over repeated
# replay, the CLS signature (fast episodic store, slow cortical weights).
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/hippocampus-memory/scripts/consolidate.sh" >/dev/null 2>&1
W1=$(jq -r '.themes["user/preferences"].weight' "$WORKSPACE/memory/cortical.json")
jq -e '.themes["user/preferences"].weight > 0.1' "$WORKSPACE/memory/cortical.json" >/dev/null
[ "$W1" = "0.2" ] || [ "$W1" = "0.2000" ]

# Workspace with an empty memory/ dir (no index) must degrade gracefully —
# the job keeps running. (The dir itself must exist: the pre-existing
# `find "$MEMORY_DIR" ... | sort` pipeline would exit non-zero under
# pipefail on a missing dir, which is the suite's established behavior.)
EMPTY=$(mktemp -d)
trap 'rm -rf "$WORKSPACE" "$EMPTY"' EXIT
mkdir -p "$EMPTY/memory"
WORKSPACE="$EMPTY" bash "$ROOT/skills/hippocampus-memory/scripts/consolidate.sh" >/dev/null 2>&1

echo "PASS: hippocampus replay consolidation"
