#!/bin/bash
# install.sh — Set up social-memory for OpenClaw
# Usage: ./install.sh [--with-cron]

set -e

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_CRON=false
[ "$1" = "--with-cron" ] && WITH_CRON=true

echo "🫂 Installing social-memory..."
echo ""

mkdir -p "$WORKSPACE/memory"

STATE_FILE="$WORKSPACE/memory/social-state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "Creating initial social state..."
  cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "",
  "relationships": {}
}
EOF
  echo "✅ Created $STATE_FILE"
else
  echo "✅ State file already exists"
fi

WATERMARK_FILE="$WORKSPACE/memory/social-watermark.json"
if [ ! -f "$WATERMARK_FILE" ]; then
  cat > "$WATERMARK_FILE" << 'EOF'
{"lastProcessedSignal": null}
EOF
fi

chmod +x "$SKILL_DIR/scripts/"*.sh
echo "✅ Scripts are executable"

"$SKILL_DIR/scripts/sync-state.sh"

if [ "$WITH_CRON" = true ]; then
  echo ""
  echo "Setting up OpenClaw cron jobs..."
  if ! command -v openclaw &> /dev/null; then
    echo "⚠️  'openclaw' not in PATH. Add these cron jobs manually:"
    echo ""
    echo "openclaw cron add --name social-decay --cron '0 0 * * *' --session isolated --agent-turn '🫂 Run $SKILL_DIR/scripts/decay.sh'"
    echo "openclaw cron add --name social-encoding --cron '50 0,3,6,9,12,15,18,21 * * *' --session isolated --agent-turn 'Run social-memory encoding pipeline'"
  else
    echo "   Creating social-decay..."
    openclaw cron add --name social-decay --cron '0 0 * * *' --session isolated \
      --agent-turn "🫂 Run $SKILL_DIR/scripts/decay.sh and report results" 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
    echo "   Creating social-encoding..."
    openclaw cron add --name social-encoding --cron '50 0,3,6,9,12,15,18,21 * * *' --session isolated \
      --agent-turn "Run social-memory encoding: 1) Run encode-pipeline.sh 2) Detect relationship signals 3) Update relationships 4) Update watermark 5) Sync state" \
      2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
  fi
  echo ""
  echo "   (Encoding offset :50 — the only free minute slot left in the suite.)"
fi

echo ""
echo "┌────────────────────────────────────────────────────────┐"
echo "│  🫂 Relationships & theory of mind — people and other  │"
echo "│     AI agents, who they are, and what's pending        │"
echo "└────────────────────────────────────────────────────────┘"
echo ""
echo "Usage:"
echo "  $SKILL_DIR/scripts/upsert-relationship.sh --id alice --name \"Alice\" --type human"
echo "  $SKILL_DIR/scripts/log-interaction.sh --id alice --summary \"...\" --trust-delta 0.05"
echo "  $SKILL_DIR/scripts/get-relationship.sh --id alice"
echo ""
[ "$WITH_CRON" != true ] && echo "TIP: ./install.sh --with-cron to enable decay + auto-encoding"
echo "Done! 🫂"
