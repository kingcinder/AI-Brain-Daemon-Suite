#!/bin/bash
# sync-state.sh — Regenerate THALAMUS_STATE.md and dashboard fragment.
set -euo pipefail
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"
OUTPUT="$WORKSPACE/THALAMUS_STATE.md"

mkdir -p "$(dirname "$OUTPUT")"

# The 🚦 dashboard fragment is always written (graceful when state missing).
[ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && bash "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true

if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$OUTPUT" << 'EOF'
# 🚦 Thalamus Attention State

**Status:** No state file yet. Run `gate.sh --process` to initialize.
EOF
    exit 0
fi

total=$(jq -r '.stats.totalSignalsProcessed // 0' "$STATE_FILE")
amp=$(jq -r '.stats.amplified // 0' "$STATE_FILE")
passed=$(jq -r '.stats.passed // 0' "$STATE_FILE")
att=$(jq -r '.stats.attenuated // 0' "$STATE_FILE")
supp=$(jq -r '.stats.suppressed // 0' "$STATE_FILE")
disp=$(jq -r '.stats.dispatchedToTargets // 0' "$STATE_FILE")
focus=$(jq -r '.attentionFocus | join(", ")' "$STATE_FILE" 2>/dev/null || echo "none")
pending=$(jq -r '.suppressedQueue | length // 0' "$STATE_FILE")
sensitivity=$(jq -r '.gateSensitivity // 0.5' "$STATE_FILE")
last=$(jq -r '.lastGateRun // "never"' "$STATE_FILE")

cat > "$OUTPUT" << EOF
# 🚦 Thalamus Attention Gate

**Last gate run:** $last
**Attention focus:** $focus
**Gate sensitivity:** $sensitivity

## Signal Processing Stats
- Total processed: $total
- 🔺 Amplified: $amp
- ✅ Passed: $passed
- 🔻 Attenuated: $att
- 🚫 Suppressed: $supp
- 📤 Dispatched to targets: $disp
- 📋 Pending in suppressed queue: $pending

## How the gate works
The thalamus scores every cross-module signal on five dimensions:
1. **Goal relevance** (35%) — Does it match an active PFC goal?
2. **Novelty bonus** (15%) — Is this a new or familiar signal?
3. **Urgency** (25%) — Signal intensity × source priority
4. **Load headroom** (25%) — Inverse of current executive load
5. **Circadian gain** (multiplier) — 1.5× active, 1.0× transition, 0.5× sleep

Signals scoring ≥0.70 are amplified, ≥0.40 pass through, ≥0.20 are attenuated,
and <0.20 are suppressed to a retry queue.
EOF

echo "✅ THALAMUS_STATE.md synced"
