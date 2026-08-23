#!/bin/bash
# ── Standardized lifecycle contract (Initiative 9) ──────────────────────────
#   install.sh              → initialize state files (defaults)
#   install.sh --uninstall  → remove exactly the state files this skill's
#                             manifest declares (delegates to skill-cleanup.sh)
if [ "${1:-}" = "--uninstall" ]; then
    THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
    WS_UN="${WORKSPACE:-$HOME/.hermes/workspace}"
    for CAND in "$THIS_DIR/../../core/skill-init/skill-cleanup.sh" \
                "$THIS_DIR/../../../core/skill-init/skill-cleanup.sh"; do
        if [ -x "$CAND" ]; then
            exec "$CAND" --skill "$THIS_DIR" --workspace "$WS_UN" "${2:-}"
        fi
    done
    echo "uninstall: skill-cleanup.sh not found — nothing removed." >&2
    exit 1
fi
# install.sh — Set up cerebellum-memory for Hermes Agent
# Usage: ./install.sh [--with-cron]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_CRON=false
[ "$1" = "--with-cron" ] && WITH_CRON=true

echo "🎚️ Installing cerebellum-memory..."
echo ""
mkdir -p "$WORKSPACE/memory"

STATE_FILE="$WORKSPACE/memory/cerebellum-state.json"
if [ ! -f "$STATE_FILE" ]; then
  cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "",
  "globalCalibration": 0.5,
  "skills": {}
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
  echo "Setting up Hermes cron job..."
  if ! command -v hermes &> /dev/null; then
    echo "⚠️  'hermes' not in PATH. Add this cron job manually:"
    echo "hermes cron create '0 */8 * * *' '🎚️ Run $SKILL_DIR/scripts/refine.sh' --name cerebellum-refine"
  else
    hermes cron create '0 */8 * * *' "🎚️ Run $SKILL_DIR/scripts/refine.sh and report results" --name cerebellum-refine 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
  fi
fi

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  🎚️ Precision & smoothness of HOW things get executed   │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "Usage:"
echo "  $SKILL_DIR/scripts/log-execution.sh --skill \"writing-code\" --quality 0.8"
echo "  $SKILL_DIR/scripts/get-calibration.sh"
echo ""
echo "Done! 🎚️"
