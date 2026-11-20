#!/bin/bash
# install.sh — Set up prefrontal-cortex-memory for OpenClaw
# Usage: ./install.sh [--with-cron]

set -e

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_CRON=false
[ "$1" = "--with-cron" ] && WITH_CRON=true

echo "🧭 Installing prefrontal-cortex-memory..."
echo ""

mkdir -p "$WORKSPACE/memory"

STATE_FILE="$WORKSPACE/memory/pfc-state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "Creating initial executive state..."
  cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "",
  "executiveLoad": 0.3,
  "goals": [],
  "inhibitions": [],
  "decisionLog": []
}
EOF
  echo "✅ Created $STATE_FILE"
else
  echo "✅ State file already exists"
fi

chmod +x "$SKILL_DIR/scripts/"*.sh
echo "✅ Scripts are executable"

"$SKILL_DIR/scripts/sync-state.sh"

if [ "$WITH_CRON" = true ]; then
  echo ""
  echo "Setting up OpenClaw cron job..."
  if ! command -v openclaw &> /dev/null; then
    echo "⚠️  'openclaw' not in PATH. Add this cron job manually:"
    echo ""
    echo "openclaw cron add --name pfc-decay --cron '0 */6 * * *' --session isolated --agent-turn '🧭 Run $SKILL_DIR/scripts/decay-load.sh'"
  else
    echo "   Creating pfc-decay..."
    openclaw cron add --name pfc-decay \
      --cron '0 */6 * * *' \
      --session isolated \
      --agent-turn "🧭 Run $SKILL_DIR/scripts/decay-load.sh and report results" \
      2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
  fi
fi

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  🧭 Executive function: goals, impulse control, arbitration │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "Usage:"
echo "  $SKILL_DIR/scripts/decide.sh --context heartbeat --options '[{\"id\":\"a\",\"label\":\"A\",\"weight\":1.0}]'"
echo "  $SKILL_DIR/scripts/goals.sh add --description \"Ship v2\" --priority 0.8"
echo "  $SKILL_DIR/scripts/inhibitions.sh add --pattern \"interrupt mid-task\" --reason \"breaks flow\""
echo "  $SKILL_DIR/scripts/get-state.sh"
echo ""
echo "NOTE: decide.sh deliberately reads sibling skills' state files (insula,"
echo "      VTA, amygdala, basal ganglia, ACC) to arbitrate — this is the one"
echo "      skill in the suite designed to do that. Every read is optional and"
echo "      degrades gracefully if a sibling isn't installed."
echo ""
echo "Done! 🧭"
