#!/bin/bash
# encode-pipeline.sh — Social signal encoding
# Usage: ./encode-pipeline.sh [--no-spawn]
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNALS_FILE="$WORKSPACE/memory/social-signals.jsonl"
NO_SPAWN="${1:-}"

# ── Closed-loop: oxytocin → social encoding bias ──────────────────────────
# Oxytocin is the "bonding hormone." When elevated (> 0.7), trust and
# affinity updates move faster — the brain is primed for social connection.
# This value is exported so sub-agents or downstream scripts can read it.
OXYTOCIN=0.5
if [ -x "$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" ]; then
    OXYTOCIN=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get oxytocin 2>/dev/null || echo "0.5")
fi
export OXYTOCIN

echo "🫂 SOCIAL ENCODING PIPELINE"
echo "============================"
echo ""
echo "📥 Step 1: Preprocessing social signals..."
"$SKILL_DIR/scripts/preprocess-mentions.sh"
echo ""

if [ ! -s "$SIGNALS_FILE" ]; then
    echo "✅ No social signals to process. Done."
    exit 0
fi

SIGNAL_COUNT=$(wc -l < "$SIGNALS_FILE" | tr -d ' ')
echo "📊 Step 2: Found $SIGNAL_COUNT social signals"
if python3 -c "import os; sys.exit(0 if float(os.environ.get('OXYTOCIN','0.5')) > 0.7 else 1)" 2>/dev/null; then
    echo "💞 Oxytocin elevated (${OXYTOCIN}): relationship updates boosted"
fi

echo ""
echo "📝 These signals need review for: new relationships, trust/affinity-relevant"
echo "   moments, and open loops (promises made). A sub-agent (or you, directly)"
echo "   should read $SIGNALS_FILE and call upsert-relationship.sh / log-interaction.sh /"
echo "   open-loops.sh as appropriate, then run:"
echo "     $SKILL_DIR/scripts/update-watermark.sh --from-signals"

if [ "$NO_SPAWN" = "--no-spawn" ]; then
    echo "⏭️  Skipping spawn (--no-spawn flag)"
    exit 0
fi

echo ""
echo "✅ Pipeline phase 1 complete. Sub-agent will handle relationship updates."
