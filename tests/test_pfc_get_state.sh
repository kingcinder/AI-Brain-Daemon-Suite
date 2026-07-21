#!/bin/bash
# Unit: PFC get-state counts active goals from pfc-state.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{
  "executiveLoad": 0.45,
  "goals": [
    {"id":"g1","description":"ship","status":"active","priority":0.8},
    {"id":"g2","description":"done","status":"complete","priority":0.5}
  ],
  "inhibitions": [{"pattern":"interrupt","strength":0.9}],
  "decisionLog": []
}
EOF
J=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/prefrontal-cortex-memory/scripts/get-state.sh" --json)
echo "$J" | jq -e '.executiveLoad == 0.45' >/dev/null
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/prefrontal-cortex-memory/scripts/get-state.sh")
echo "$OUT" | grep -q '0.45'
echo "$OUT" | grep -q 'Active goals'
echo "$OUT" | grep -q '1'   # one active goal
echo "PASS: pfc get-state"
