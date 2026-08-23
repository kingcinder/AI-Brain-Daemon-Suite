#!/bin/bash
# Unit: VTA log-reward computes a Schultz-style TD reward-prediction error
# (RPE = reward − expected) and updates the per-type expected value toward
# observed reward — asserts the error signal actually occurs, not just that
# the script runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/reward-state.json" << 'EOF'
{"drive":0.5,"recentRewards":[],"rewardHistory":{"totalRewards":0,"byType":{}}}
EOF

# NOTE: the seed intentionally OMITS expectedReward/recentRPE — the exact
# shape of pre-audit production state files. The script must handle the
# missing keys (null-safe // [] / auto-vivify), so this test doubles as the
# regression lock for the reviewer-flagged jq null+array bug.

# Reward ABOVE the 0.5 default expectation (0.9) → positive RPE = +0.4,
# expected moves 0.5 → 0.62 (α=0.3), drive boosted by tonic + phasic.
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/vta-memory/scripts/log-reward.sh" --type accomplishment --source "shipped feature" --intensity 0.9 >/dev/null
jq -e '.recentRPE | length == 1' "$WORKSPACE/memory/reward-state.json" >/dev/null
jq -e '.recentRPE[0].rpe > 0.3 and .recentRPE[0].rpe < 0.5' "$WORKSPACE/memory/reward-state.json" >/dev/null
jq -e '.recentRPE[0].expectedBefore == 0.5' "$WORKSPACE/memory/reward-state.json" >/dev/null
jq -e '.expectedReward.accomplishment > 0.6 and .expectedReward.accomplishment < 0.64' "$WORKSPACE/memory/reward-state.json" >/dev/null
jq -e '.drive > 0.5' "$WORKSPACE/memory/reward-state.json" >/dev/null

# Reward BELOW the updated expectation (0.3) → negative RPE, expected drifts
# back down — the TD delta rule tracks the environment in both directions.
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/vta-memory/scripts/log-reward.sh" --type accomplishment --source "underwhelming" --intensity 0.3 >/dev/null
jq -e '.recentRPE[0].rpe < 0' "$WORKSPACE/memory/reward-state.json" >/dev/null
jq -e '.expectedReward.accomplishment < 0.62' "$WORKSPACE/memory/reward-state.json" >/dev/null

echo "PASS: vta TD reward-prediction-error"
