#!/bin/bash
# encode-pipeline.sh — Social signal encoding
# Usage: ./encode-pipeline.sh [--no-spawn]
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNALS_FILE="$WORKSPACE/memory/social-signals.jsonl"
NO_SPAWN="${1:-}"

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
