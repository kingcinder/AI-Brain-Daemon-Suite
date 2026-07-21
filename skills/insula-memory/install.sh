#!/usr/bin/env bash
# install.sh — Set up insula-memory
# Usage: ./install.sh [--with-cron]
set -e

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_DIR="$WORKSPACE/memory"
STATE_FILE="$MEMORY_DIR/interoceptive-state.json"
WITH_CRON=false
[[ "${1:-}" == "--with-cron" ]] && WITH_CRON=true

echo "🌡️ Installing insula-memory..."

# 1. Directories
mkdir -p "$MEMORY_DIR"
echo "   ✅ Memory directory: $MEMORY_DIR"

# 2. State file
if [ ! -f "$STATE_FILE" ]; then
  cat > "$STATE_FILE" << 'JSON'
{
  "version": "1.0",
  "lastUpdated": null,
  "channels": {
    "gutSignal": 0.10,
    "cognitiveLoad": 0.30,
    "friction": 0.10,
    "somaticComfort": 0.30,
    "empathicResonance": 0.40,
    "selfCoherence": 0.70,
    "contextSaturation": 0.20
  },
  "baseline": {
    "gutSignal": 0.10,
    "cognitiveLoad": 0.30,
    "friction": 0.10,
    "somaticComfort": 0.30,
    "empathicResonance": 0.40,
    "selfCoherence": 0.70,
    "contextSaturation": 0.20
  },
  "recentSignals": [],
  "lastProcessedSignal": null,
  "stats": { "totalSignalsLogged": 0 }
}
JSON
  echo "   ✅ Created interoceptive-state.json"
else
  echo "   ℹ️  interoceptive-state.json already exists (skipped)"
fi

# 3. Make scripts executable
chmod +x "$SKILL_DIR"/scripts/*.sh 2>/dev/null || true

# 4. Generate initial INSULA_STATE.md
"$SKILL_DIR/scripts/sync-state.sh" 2>/dev/null && echo "   ✅ Generated INSULA_STATE.md" || true

# 5. Dashboard
"$SKILL_DIR/scripts/generate-dashboard.sh" 2>/dev/null && echo "   ✅ Brain Dashboard updated" || true

# 6. Cron
if [ "$WITH_CRON" = true ]; then
  echo ""
  echo "⏰ Setting up cron jobs..."
  if ! command -v openclaw &>/dev/null; then
    echo "   ⚠️  'openclaw' not in PATH. Add manually:"
    echo ""
    echo "   openclaw cron add --name insula-encoding --cron '40 0,3,6,9,12,15,18,21 * * *' \\"
    echo "     --session isolated --agent-turn 'Run insula sense encoding pipeline'"
    echo ""
    echo "   openclaw cron add --name insula-decay --cron '0 */4 * * *' \\"
    echo "     --session isolated --agent-turn 'Run insula decay: scripts/decay-sense.sh'"
  else
    openclaw cron add --name insula-encoding \
      --cron '40 0,3,6,9,12,15,18,21 * * *' \
      --session isolated \
      --agent-turn "Run insula sense encoding: preprocess signals, detect interoceptive patterns, update state, sync INSULA_STATE.md"
    openclaw cron add --name insula-decay \
      --cron '0 */4 * * *' \
      --session isolated \
      --agent-turn "🌡️ Run decay-sense.sh and report current interoceptive state"
    echo "   ✅ Cron jobs registered"
  fi
fi

echo ""
echo "🌡️ Insula installed!"
echo "   View dashboard: $WORKSPACE/brain-dashboard.html"
echo "   Session start:  $SKILL_DIR/scripts/load-sense.sh"
