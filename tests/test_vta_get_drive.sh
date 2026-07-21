#!/bin/bash
# Unit: VTA get-drive reports drive + reward totals from reward-state.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/reward-state.json" << 'EOF'
{"drive":0.65,"rewardHistory":{"totalRewards":7,"recent":[]}}
EOF
J=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/vta-memory/scripts/get-drive.sh" --json)
echo "$J" | jq -e '.drive == 0.65 and .rewardHistory.totalRewards == 7' >/dev/null
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/vta-memory/scripts/get-drive.sh")
echo "$OUT" | grep -q 'Motivation'
echo "$OUT" | grep -qE '0\.65|motivated'
echo "PASS: vta get-drive"
