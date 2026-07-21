#!/usr/bin/env bash
# scripts/flag-attention.sh — Add or remove attention flags for risky topics
#
# Usage:
#   ./flag-attention.sh --add "topic name" --reason "why it needs attention"
#   ./flag-attention.sh --remove "topic name"
#   ./flag-attention.sh --list

set -e

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"

ACTION=""
TOPIC=""
REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)    ACTION="add";    TOPIC="$2"; shift 2 ;;
    --remove) ACTION="remove"; TOPIC="$2"; shift 2 ;;
    --list)   ACTION="list";   shift ;;
    --reason) REASON="$2";     shift 2 ;;
    --help|-h)
      sed -n '2,8p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$ACTION" ]] && ACTION="list"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: conflict-state.json not found. Run ./install.sh first." >&2; exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$ACTION" in
  list)
    COUNT=$(jq '.attentionFlags | length' "$STATE_FILE")
    if [[ "$COUNT" -eq 0 ]]; then
      echo "⚡ No attention flags set."
    else
      echo "⚡ Attention flags ($COUNT):"
      jq -r '.attentionFlags[] | "   📌 \(.topic)\n      \(.reason)"' "$STATE_FILE"
    fi
    ;;

  add)
    [[ -z "$TOPIC" ]] && { echo "ERROR: topic required with --add" >&2; exit 1; }

    # Check if already flagged
    EXISTS=$(jq --arg t "$TOPIC" '.attentionFlags[] | select(.topic == $t) // empty' "$STATE_FILE")
    if [[ -n "$EXISTS" ]]; then
      echo "⚡ '$TOPIC' is already flagged for attention."
      exit 0
    fi

    UPDATED=$(jq \
      --arg topic "$TOPIC" \
      --arg reason "${REASON:-flagged for attention}" \
      --arg now "$NOW" \
      '
      .attentionFlags += [{topic: $topic, reason: $reason, addedAt: $now}] |
      .lastUpdated = $now |
      .stats.totalAttentionFlags += 1
      ' "$STATE_FILE")

    echo "$UPDATED" > "$STATE_FILE"
    "$SKILL_DIR/scripts/sync-state.sh" --quiet
    echo "⚡ Flagged for attention: $TOPIC"
    [[ -n "$REASON" ]] && echo "   Reason: $REASON"
    ;;

  remove)
    [[ -z "$TOPIC" ]] && { echo "ERROR: topic required with --remove" >&2; exit 1; }

    UPDATED=$(jq \
      --arg topic "$TOPIC" \
      --arg now "$NOW" \
      '
      .attentionFlags = [.attentionFlags[] | select(.topic != $topic)] |
      .lastUpdated = $now
      ' "$STATE_FILE")

    echo "$UPDATED" > "$STATE_FILE"
    "$SKILL_DIR/scripts/sync-state.sh" --quiet
    echo "⚡ Removed attention flag: $TOPIC"
    ;;
esac
