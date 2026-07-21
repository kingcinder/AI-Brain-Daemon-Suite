#!/bin/bash
# Unit: amygdala get-state reads emotional-state dimensions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/emotional-state.json" << 'EOF'
{"dimensions":{"valence":0.72,"arousal":0.31,"connection":0.55,"curiosity":0.8,"energy":0.4}}
EOF
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/amygdala-memory/scripts/get-state.sh" --dimension valence)
echo "$OUT" | grep -q '0.72'
J=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/amygdala-memory/scripts/get-state.sh" --json)
echo "$J" | jq -e '.dimensions.valence == 0.72 and .dimensions.curiosity == 0.8' >/dev/null
echo "PASS: amygdala get-state"
