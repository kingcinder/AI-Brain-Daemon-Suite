#!/bin/bash
# Skill-specific test: social-memory list-relationships must list named relationships
# from social-state.json — fails if list-relationships.sh does not walk .relationships.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/skills/social-memory/scripts/list-relationships.sh"
export WORKSPACE
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/social-state.json" << 'EOF'
{
  "relationships": {
    "alice": {
      "name": "Alice",
      "type": "human",
      "trust": 0.7,
      "affinity": 0.6,
      "interactionCount": 4
    },
    "bot-1": {
      "name": "BotOne",
      "type": "ai_agent",
      "trust": 0.4,
      "affinity": 0.3,
      "interactionCount": 1
    }
  }
}
EOF
chmod +x "$SCRIPT"
OUT=$(WORKSPACE="$WORKSPACE" bash "$SCRIPT")
echo "$OUT" | grep -q 'Alice'
echo "$OUT" | grep -q 'trust 0.7'
OUT_H=$(WORKSPACE="$WORKSPACE" bash "$SCRIPT" --type human)
echo "$OUT_H" | grep -q 'Alice'
echo "$OUT_H" | grep -vq 'BotOne' || {
  # if bot appears, filter failed
  if echo "$OUT_H" | grep -q 'BotOne'; then
    echo "FAIL: type filter human still shows ai_agent" >&2
    exit 1
  fi
}
echo "PASS: social list-relationships skill-specific"
