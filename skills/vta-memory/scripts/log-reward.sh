#!/bin/bash
# log-reward.sh — Log a reward event and boost drive
# Usage: ./log-reward.sh --type <type> --source "what happened" [--intensity 0-1]
#
# Types: accomplishment, social, curiosity, connection, creative, competence

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/reward-state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ No reward state found at $STATE_FILE"
  exit 1
fi

# Serialize read-modify-write against the other reward-state.json writers.
exec 200>"$STATE_FILE.lock"
flock 200

# Parse arguments
TYPE=""
SOURCE=""
INTENSITY="0.5"

while [[ $# -gt 0 ]]; do
  case $1 in
    --type)
      TYPE="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --intensity)
      INTENSITY="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$TYPE" ] || [ -z "$SOURCE" ]; then
  echo "Usage: $0 --type <type> --source \"what happened\" [--intensity 0-1]"
  echo ""
  echo "Types: accomplishment, social, curiosity, connection, creative, competence"
  exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── TD reward-prediction error (Schultz; Sutton & Barto TD(0) delta rule) ──
# Expected value per reward type (default 0.5). RPE = reward − expected.
# Expected tracks the observed reward with α=0.3. Drive boost = tonic
# (intensity·0.2, exactly as before) + phasic max(0, RPE)·0.15 — dopamine
# encodes the PREDICTION ERROR, so a reward that merely meets expectation
# gets no phasic boost, and a below-expectation reward gets none either.
TD=$(python3 - "$STATE_FILE" "$TYPE" "$INTENSITY" << 'PYTHON'
import json, sys
state = json.load(open(sys.argv[1]))
expected = float(state.get('expectedReward', {}).get(sys.argv[2], 0.5))
intensity = float(sys.argv[3])
alpha = 0.3
rpe = round(intensity - expected, 4)
new_expected = round(expected + alpha * rpe, 4)
tonic = round(intensity * 0.2, 4)
phasic = round(max(0.0, rpe) * 0.15, 4)
print(f"{expected:.4f} {rpe:.4f} {new_expected:.4f} {round(tonic + phasic, 4):.4f}")
PYTHON
)
read -r EXPECTED RPE NEW_EXPECTED BOOST <<< "$TD"

# Get current drive
CURRENT_DRIVE=$(jq -r '.drive' "$STATE_FILE")

# Calculate new drive (capped at 1.0)
NEW_DRIVE=$(awk -v d="$CURRENT_DRIVE" -v b="$BOOST" 'BEGIN {v=d+b; if(v>1)print 1; else printf "%.2f", v}')

# Create reward entry (with the prediction error attached)
REWARD_ENTRY=$(jq -n \
  --arg type "$TYPE" \
  --arg source "$SOURCE" \
  --arg intensity "$INTENSITY" \
  --arg boost "$BOOST" \
  --argjson rpe "$RPE" \
  --argjson expected "$EXPECTED" \
  --argjson newExpected "$NEW_EXPECTED" \
  --arg ts "$NOW" \
  '{type: $type, source: $source, intensity: ($intensity|tonumber), boost: ($boost|tonumber), rpe: $rpe, expectedBefore: $expected, expectedAfter: $newExpected, timestamp: $ts}')

RPE_ENTRY=$(echo "$REWARD_ENTRY" | jq '{type, rpe, expectedBefore, expectedAfter, timestamp}')

# Update state file
jq --argjson reward "$REWARD_ENTRY" \
   --argjson rpeEntry "$RPE_ENTRY" \
   --argjson newDrive "$NEW_DRIVE" \
   --argjson newExpected "$NEW_EXPECTED" \
   --arg now "$NOW" \
   --arg type "$TYPE" \
   '
   .drive = $newDrive |
   .lastUpdated = $now |
   .recentRewards = ([$reward] + .recentRewards | .[0:10]) |
   .rewardHistory.totalRewards += 1 |
   .rewardHistory.byType[$type] += 1 |
   .expectedReward[$type] = $newExpected |
   .recentRPE = ([$rpeEntry] + (.recentRPE // []) | .[0:10])
   ' "$STATE_FILE" > "$STATE_FILE.tmp.$$"
mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

# Append to persistent reward log
LOG_FILE="$WORKSPACE/memory/reward-log.jsonl"
echo "$REWARD_ENTRY" >> "$LOG_FILE"

echo "⭐ Reward logged!"
echo "   Type: $TYPE"
echo "   Source: $SOURCE"
echo "   Intensity: $INTENSITY"
echo "   RPE: $(printf '%+.2f' "$RPE") (expected $EXPECTED → $NEW_EXPECTED)"
echo "   Drive: $CURRENT_DRIVE → $NEW_DRIVE (+$BOOST)"
