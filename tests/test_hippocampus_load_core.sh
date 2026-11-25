#!/bin/bash
# Unit: hippocampus load-core filters by importance threshold.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/index.json" << 'EOF'
{"memories":[
  {"id":"m1","importance":0.9,"content":"core fact A"},
  {"id":"m2","importance":0.5,"content":"peripheral B"},
  {"id":"m3","importance":0.75,"content":"core fact C"}
]}
EOF
OUT=$(WORKSPACE="$WORKSPACE" THRESHOLD=0.7 bash "$ROOT/skills/hippocampus-memory/scripts/load-core.sh")
echo "$OUT" | grep -q '2 core memories'
# content fields may render differently; assert count filter is skill-specific
OUT2=$(WORKSPACE="$WORKSPACE" THRESHOLD=0.95 bash "$ROOT/skills/hippocampus-memory/scripts/load-core.sh")
echo "$OUT2" | grep -qiE 'No core memories|0 core'
# mid threshold: only m1
OUT3=$(WORKSPACE="$WORKSPACE" THRESHOLD=0.85 bash "$ROOT/skills/hippocampus-memory/scripts/load-core.sh")
echo "$OUT3" | grep -q '1 core memories'
echo "PASS: hippocampus load-core"
