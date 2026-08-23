#!/bin/bash
# Unit: Insula update-state tracks an interoceptive prediction error
# (Craig's predictive-coding model): each channel has a predicted prior, and
# the discrepancy |actual − predicted| is recorded when a signal lands far
# from expectation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/interoceptive-state.json" << 'EOF'
{"channels":{},"recentSignals":[]}
EOF

# 'discord' slams gutSignal −0.4·0.6 = −0.24 against the 0.1 prior → the
# sensed channel lands at −0.14, PE = 0.24 ≥ 0.05 → recorded.
# NOTE: insula scripts honor OPENCLAW_WORKSPACE (not WORKSPACE) — the
# existing test_insula_state.sh sets both; must do the same or the script
# silently operates on the live ~/.hermes/workspace.
WORKSPACE="$WORKSPACE" OPENCLAW_WORKSPACE="$WORKSPACE" bash "$ROOT/skills/insula-memory/scripts/update-state.sh" --signal discord --intensity 0.6 >/dev/null
jq -e '.recentDiscrepancies | length >= 1' "$WORKSPACE/memory/interoceptive-state.json" >/dev/null
jq -e '[.recentDiscrepancies[].error] | any(. > 0.15)' "$WORKSPACE/memory/interoceptive-state.json" >/dev/null
jq -e '.predictedChannels.gutSignal != null' "$WORKSPACE/memory/interoceptive-state.json" >/dev/null
jq -e '.composite.interoceptiveDiscrepancy > 0' "$WORKSPACE/memory/interoceptive-state.json" >/dev/null
# Channel value actually moved (the sensed state was updated)
jq -e '.channels.gutSignal < 0' "$WORKSPACE/memory/interoceptive-state.json" >/dev/null

# A second pass updates the prior toward the sensed state (predicted tracks
# actual with α=0.2) — the discrepancy mechanism is persistent, not one-shot.
WORKSPACE="$WORKSPACE" OPENCLAW_WORKSPACE="$WORKSPACE" bash "$ROOT/skills/insula-memory/scripts/update-state.sh" --signal ease --intensity 0.4 >/dev/null
jq -e '.predictedChannels.gutSignal != null' "$WORKSPACE/memory/interoceptive-state.json" >/dev/null

echo "PASS: insula interoceptive prediction error"
