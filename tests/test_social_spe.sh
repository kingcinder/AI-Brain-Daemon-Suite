#!/bin/bash
# Unit: Social log-interaction updates trust by a Behrens-style social
# prediction error (SPE = outcome − expected) when both are supplied —
# associative social-value learning, not caller-supplied deltas.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/social-state.json" << 'EOF'
{"relationships":{"alice":{"name":"Alice","trust":0.5,"affinity":0.5,"notes":[],"interactionCount":0,"lastContact":null,"beliefs":{},"openLoops":[],"firstContact":"2026-08-23T00:00:00Z"}}}
EOF

# Expected 0.3, outcome 0.9 → SPE 0.6 → trust +0.12 (α=0.2), affinity +0.06.
# The interaction is recorded in recentSPE.
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/social-memory/scripts/log-interaction.sh" --id alice --summary "great call" --expected 0.3 --outcome 0.9 >/dev/null
jq -e '.relationships.alice.trust > 0.6 and .relationships.alice.trust < 0.63' "$WORKSPACE/memory/social-state.json" >/dev/null
jq -e '.relationships.alice.affinity > 0.55 and .relationships.alice.affinity < 0.57' "$WORKSPACE/memory/social-state.json" >/dev/null
jq -e '.recentSPE | length == 1' "$WORKSPACE/memory/social-state.json" >/dev/null
jq -e '.recentSPE[0].spe == 0.6' "$WORKSPACE/memory/social-state.json" >/dev/null

# Negative surprise: expected 0.9, outcome 0.2 → SPE −0.7 → trust drops
# by 0.14 — trust is driven by the surprise, both directions.
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/social-memory/scripts/log-interaction.sh" --id alice --summary "flaked" --expected 0.9 --outcome 0.2 >/dev/null
jq -e '.recentSPE[0].spe < 0' "$WORKSPACE/memory/social-state.json" >/dev/null
jq -e '.relationships.alice.trust < 0.5' "$WORKSPACE/memory/social-state.json" >/dev/null

# Explicit-delta path (legacy) still works and records NO SPE entry
N=$(jq -r '.recentSPE | length' "$WORKSPACE/memory/social-state.json")
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/social-memory/scripts/log-interaction.sh" --id alice --summary "meh" --trust-delta 0.1 >/dev/null
jq -e --argjson n "$N" '.recentSPE | length == $n' "$WORKSPACE/memory/social-state.json" >/dev/null
jq -e '.relationships.alice.interactionCount == 3' "$WORKSPACE/memory/social-state.json" >/dev/null

echo "PASS: social prediction-error trust updating"
