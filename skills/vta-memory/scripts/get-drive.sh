#!/bin/bash
# get-drive.sh — Read current motivation/drive state
# Usage: ./get-drive.sh [--json]

set -e

# JUNO-BC-PATH (2026-11-15, Dither-ordered): cron env lacks interactive PATH; bc lives in home.
export PATH="$HOME/.juno-brain/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
command -v bc >/dev/null 2>&1 || ln -sf "$HOME/.juno-brain/bin/bc" /usr/local/bin/bc 2>/dev/null || true

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/reward-state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ No reward state found at $STATE_FILE"
  exit 1
fi

if [ "$1" = "--json" ]; then
  cat "$STATE_FILE"
else
  DRIVE=$(jq -r '.drive' "$STATE_FILE")
  TOTAL=$(jq -r '.rewardHistory.totalRewards' "$STATE_FILE")
  
  # Interpret drive level
  if (( $(echo "$DRIVE > 0.8" | bc -l) )); then
    DRIVE_DESC="highly motivated"
  elif (( $(echo "$DRIVE > 0.6" | bc -l) )); then
    DRIVE_DESC="motivated"
  elif (( $(echo "$DRIVE > 0.4" | bc -l) )); then
    DRIVE_DESC="moderate drive"
  elif (( $(echo "$DRIVE > 0.2" | bc -l) )); then
    DRIVE_DESC="low motivation"
  else
    DRIVE_DESC="unmotivated"
  fi
  
  echo "⭐ Motivation State"
  echo "─────────────────────"
  echo ""
  echo "Drive: $DRIVE ($DRIVE_DESC)"
  echo "Total rewards: $TOTAL"
  echo ""
  
  # Show what we're seeking
  SEEKING=$(jq -r '.seeking[]?' "$STATE_FILE" 2>/dev/null)
  if [ -n "$SEEKING" ]; then
    echo "Currently seeking:"
    echo "$SEEKING" | while read -r item; do
      echo "  • $item"
    done
    echo ""
  fi
  
  # Show what we're anticipating
  ANTICIPATING=$(jq -r '.anticipating[]?' "$STATE_FILE" 2>/dev/null)
  if [ -n "$ANTICIPATING" ]; then
    echo "Looking forward to:"
    echo "$ANTICIPATING" | while read -r item; do
      echo "  • $item"
    done
    echo ""
  fi
  
  # Recent rewards
  echo "Recent rewards:"
  jq -r '.recentRewards[:3][] | "  • \(.type): \(.source) (+\(.boost))"' "$STATE_FILE" 2>/dev/null || echo "  (none yet)"
fi
