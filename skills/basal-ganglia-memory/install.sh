#!/bin/bash
# Basal Ganglia Skill Installer
# Sets up the habit registry, habit-state.json, and optionally cron jobs
#
# Usage: ./install.sh [options]
#
# Options:
#   --with-cron       Set up cron jobs for encoding and decay
#   --signals N       Process last N signals on first encoding (default: 100)
#   --whole           Process entire conversation history (no limit)
#
# Examples:
#   ./install.sh                    # Basic install, first encoding uses last 100 signals
#   ./install.sh --signals 50       # First encoding uses last 50 signals
#   ./install.sh --whole            # First encoding processes entire history
#   ./install.sh --with-cron        # Also sets up cron jobs

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"

WITH_CRON=false
SIGNAL_LIMIT=100
WHOLE_HISTORY=false

# Parse --signals N, --whole, --with-cron
while [[ $# -gt 0 ]]; do
    case $1 in
        --with-cron)
            WITH_CRON=true
            shift
            ;;
        --signals)
            SIGNAL_LIMIT="$2"
            shift 2
            ;;
        --whole)
            WHOLE_HISTORY=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "🎯 Basal Ganglia Skill Installer"
echo "================================="
echo ""
echo "Workspace: $WORKSPACE"
echo "Skill dir: $SKILL_DIR"
if [ "$WHOLE_HISTORY" = true ]; then
    echo "First encoding: ENTIRE history"
else
    echo "First encoding: last $SIGNAL_LIMIT signals"
fi
echo ""

# 1. Create memory directory if needed
echo "📁 Creating memory directory..."
mkdir -p "$WORKSPACE/memory"
echo "   ✅ $WORKSPACE/memory/ ready"

# 2. Initialize habit-state.json if it doesn't exist
STATE_FILE="$WORKSPACE/memory/habit-state.json"
if [ ! -f "$STATE_FILE" ]; then
    echo "📄 Initializing habit-state.json..."
    cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": null,
  "decayLastRun": null,
  "lastProcessedSignal": null,
  "habits": [],
  "procedures": [],
  "suppressions": []
}
EOF
    echo "   ✅ Created memory/habit-state.json"
else
    echo "   ⏭️  memory/habit-state.json already exists"
fi

# 3. Store signal limit preference (namespaced so it doesn't collide
#    with other brain skills that keep their own preference file)
if [ "$WHOLE_HISTORY" = true ]; then
    echo "whole" > "$WORKSPACE/memory/.basal-ganglia-signal-limit"
else
    echo "$SIGNAL_LIMIT" > "$WORKSPACE/memory/.basal-ganglia-signal-limit"
fi
echo "   ✅ Signal limit set: $(cat "$WORKSPACE/memory/.basal-ganglia-signal-limit")"

# 4. Make scripts executable
echo "🔧 Making scripts executable..."
chmod +x "$SKILL_DIR/"*.sh 2>/dev/null || true
chmod +x "$SKILL_DIR/scripts/"*.sh 2>/dev/null || true
echo "   ✅ All scripts are executable"

# 5. Set up cron jobs (optional)
if [ "$WITH_CRON" = true ]; then
    echo ""
    echo "⏰ Setting up cron jobs..."

    if ! command -v hermes &> /dev/null; then
        echo "   ⚠️  'hermes' not in PATH. Add these cron jobs manually:"
        echo ""
        echo "# Encoding every 3 hours (habit detection + reinforcement)"
        echo "hermes cron create '30 0,3,6,9,12,15,18,21 * * *' 'Run basal-ganglia encoding pipeline...' --name basal-ganglia-encoding"
        echo ""
        echo "# Daily decay at 4 AM"
        echo "hermes cron create '0 4 * * *' '🎯 Run decay-habits.sh and report any habits below 0.2' --name basal-ganglia-decay"
    else
        echo "   Creating basal-ganglia-encoding..."
        hermes cron create '30 0,3,6,9,12,15,18,21 * * *' "Run basal-ganglia encoding pipeline:\n\n1. Run the encoding pipeline:\n\`\`\`bash\nWORKSPACE=\"\$HOME/.hermes/workspace\" ~/.hermes/workspace/skills/basal-ganglia-memory/scripts/encode-pipeline.sh --no-spawn\n\`\`\`\n\n2. Check pending habits:\n\`\`\`bash\ncat ~/.hermes/workspace/memory/pending-habits.json 2>/dev/null | head -40\n\`\`\`\n\n3. For each pending signal, classify per prompts/encode-habits.md: new habit, reinforce existing habit/procedure, or new suppression\n4. Update habit-state.json with the result (use reinforce-habit.sh for updates where possible)\n5. Delete pending-habits.json when done\n6. Sync state: ~/.hermes/workspace/skills/basal-ganglia-memory/scripts/sync-state.sh\n7. Report results" --name basal-ganglia-encoding 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"

        echo "   Creating basal-ganglia-decay..."
        hermes cron create '0 4 * * *' "🎯 Run habit decay:\n\n1. Run: ~/.hermes/workspace/skills/basal-ganglia-memory/scripts/decay-habits.sh\n2. Report any habits/procedures that dropped below 0.2 (candidates for pruning)\n3. Confirm decay complete" --name basal-ganglia-decay 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
    fi
    echo ""
fi

# 6. Generate initial BASAL_GANGLIA_STATE.md (and regenerate dashboard)
echo "🔄 Generating BASAL_GANGLIA_STATE.md..."
WORKSPACE="$WORKSPACE" "$SKILL_DIR/scripts/sync-state.sh" 2>/dev/null || echo "   (no habits yet)"

echo ""
echo "✅ Installation complete!"
echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  🎯 View your agent's HABITS in the Brain Dashboard        │"
echo "│                                                            │"
echo "│  open ~/.hermes/workspace/brain-dashboard.html           │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "Next steps:"
echo "  1. Run first encoding: $SKILL_DIR/scripts/encode-pipeline.sh"
echo "  2. The encoding will process the last $([ "$WHOLE_HISTORY" = true ] && echo 'ALL' || echo "$SIGNAL_LIMIT") signals"
echo "  3. Add memory/habit-state.json to .gitignore (contains behavioral data)"
echo "  4. Test loading: $SKILL_DIR/load-habits.sh"
echo ""
echo "See SKILL.md for full usage instructions."
