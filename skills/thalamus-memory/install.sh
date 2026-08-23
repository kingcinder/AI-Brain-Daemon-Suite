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
# install.sh — Set up thalamus-memory for the AI Brain Suite.
# Usage: ./install.sh [--with-cron]
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_CRON=false
[[ "${1:-}" = "--with-cron" ]] && WITH_CRON=true

echo "🚦 Installing thalamus-memory (attention gating + signal routing)..."
echo ""

# ── Create directories ──────────────────────────────────────────────────
mkdir -p "$WORKSPACE/memory"
mkdir -p "$WORKSPACE/memory/.signal-checkpoints"

# ── Initialize state file ───────────────────────────────────────────────
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"
if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "",
  "attentionFocus": [],
  "suppressedQueue": [],
  "stats": {
    "totalSignalsProcessed": 0,
    "amplified": 0,
    "passed": 0,
    "attenuated": 0,
    "suppressed": 0,
    "dispatchedToTargets": 0
  },
  "gateSensitivity": 0.5,
  "lastGateRun": ""
}
EOF
    echo "✅ Created thalamus-state.json"
else
    echo "✅ State file already exists"
fi

# ── Make scripts executable ─────────────────────────────────────────────
chmod +x "$SKILL_DIR/scripts/"*.sh
echo "✅ Scripts are executable"

# ── Also make core/signaling scripts executable ─────────────────────────
CORE_SIGNALING="$SKILL_DIR/../../core/signaling"
if [[ -d "$CORE_SIGNALING" ]]; then
    chmod +x "$CORE_SIGNALING/"*.sh 2>/dev/null || true
fi

# ── Initial state sync ──────────────────────────────────────────────────
"$SKILL_DIR/scripts/sync-state.sh" 2>/dev/null || true

# ── Register cron if requested ──────────────────────────────────────────
if [[ "$WITH_CRON" = true ]]; then
    echo ""
    echo "📋 Cron jobs for thalamus will be managed by deep-brain-kernel.py"
    echo "   (thalamus_gate and signal_dispatch jobs added to JOBS table)"
    echo "   No manual cron setup needed."
fi

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  🚦 Thalamus — Attentional gating & signal routing      │"
echo "│     The brain's searchlight of attention.               │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "Next steps:"
echo "  1. The daemon will schedule thalamus gate processing"
echo "  2. Skills publish signals via core/signaling/publish.sh"
echo "  3. Check: $SKILL_DIR/scripts/gate.sh --status"
echo ""
echo "Done! 🚦"
