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
# Verification-memory Skill Installer
# Sets up the verification state file, report ledger, and dashboard fragment.
#
# Usage: ./install.sh
#
# The verification region itself is manifest-driven: it needs no per-skill
# wiring beyond what each module's capability-manifest.json already declares
# in its `tests` array. This installer only bootstraps this skill's own state.

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🩺 Verification-memory Skill Installer"
echo "======================================"
echo ""
echo "Workspace: $WORKSPACE"
echo "Skill dir: $SKILL_DIR"
echo ""

# 1. Create memory directories
echo "📁 Creating memory directories..."
mkdir -p "$WORKSPACE/memory"
echo "   ✅ Ready"

# 2. Initialize verification state if not exists
STATE_FILE="$WORKSPACE/memory/verification-state.json"
if [ ! -f "$STATE_FILE" ]; then
    echo "📄 Initializing verification-state.json..."
    cat > "$STATE_FILE" << 'EOF'
{
  "schema": 1,
  "lastRun": null,
  "moduleFilter": "all",
  "totals": {"tests": 0, "passed": 0, "failed": 0, "skipped": 0},
  "lastFailure": null
}
EOF
    echo "   ✅ Created verification-state.json"
else
    echo "   ⏭️  verification-state.json already exists"
fi

# 3. Make scripts executable
echo "🔧 Making scripts executable..."
chmod +x "$SKILL_DIR/scripts/"*.sh
echo "   ✅ All scripts are executable"

echo ""
echo "✅ Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Run a full sweep:  $SKILL_DIR/scripts/run-declared-tests.sh"
echo "  2. Targeted check:    $SKILL_DIR/scripts/run-module-tests.sh --module acc-error-memory"
echo "  3. The daemon's JOBS table already schedules verification_pass (07:56 UTC daily)."
echo ""
echo "See SKILL.md for the signal routes this region registers."
