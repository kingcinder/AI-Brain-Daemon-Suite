#!/bin/bash
# Unit: anterior-cingulate get-state dumps conflict-state.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/conflict-state.json" << 'EOF'
{"conflicts":[{"id":"c1","description":"schedule vs deep work","status":"open"}],"load":0.4}
EOF
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/anterior-cingulate-memory/scripts/get-state.sh")
echo "$OUT" | jq -e '.conflicts[0].id == "c1" and .load == 0.4' >/dev/null
echo "PASS: acc conflict get-state"
