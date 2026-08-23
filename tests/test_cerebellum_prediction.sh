#!/bin/bash
# Unit: Cerebellum log-execution records a Wolpert/Miall/Kawato forward-model
# prediction error (PE = |predicted − actual|) when --predicted is supplied,
# and gates the learning rate on prediction accuracy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/cerebellum-state.json" << 'EOF'
{"skills":{"deploy":{"precision":0.5,"smoothness":0.5,"reps":1,"lastRefined":"2026-08-23T00:00:00Z","recentCorrections":[],"recentPredictions":[]}}}
EOF

# Accurate prediction (predicted 0.9, actual 0.8 → PE 0.1): error recorded,
# predictionError EMA initialized to 0.1.
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/cerebellum-memory/scripts/log-execution.sh" --skill deploy --quality 0.8 --predicted 0.9 >/dev/null
jq -e '.skills.deploy.recentPredictions | length == 1' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null
jq -e '.skills.deploy.recentPredictions[0].error == 0.1' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null
jq -e '.skills.deploy.predictionError == 0.1' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null

# Wildly off prediction (predicted 0.2, actual 0.8 → PE 0.6): recorded, EMA
# moves toward 0.25, and learning rate is damped (alpha_eff = 0.3·0.6).
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/cerebellum-memory/scripts/log-execution.sh" --skill deploy --quality 0.8 --predicted 0.2 >/dev/null
jq -e '.skills.deploy.recentPredictions | length == 2' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null
jq -e '.skills.deploy.recentPredictions[0].error == 0.6' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null
jq -e '.skills.deploy.predictionError > 0.2 and .skills.deploy.predictionError < 0.3' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null

# No --predicted → byte-identical legacy path (no prediction fields written)
P0=$(jq -r '.skills.deploy.recentPredictions | length' "$WORKSPACE/memory/cerebellum-state.json")
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/cerebellum-memory/scripts/log-execution.sh" --skill deploy --quality 0.8 >/dev/null
jq -e --argjson n "$P0" '.skills.deploy.recentPredictions | length == $n' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null

# Brand-new skill with --predicted records the PE on its very FIRST rep
# (create-path fix — the reviewer-flagged gap is now regression-locked).
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/cerebellum-memory/scripts/log-execution.sh" --skill fresh --quality 0.7 --predicted 0.5 >/dev/null
jq -e '.skills.fresh.predictionError == 0.2' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null
jq -e '.skills.fresh.recentPredictions | length == 1' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null
jq -e '.skills.fresh.recentPredictions[0].error == 0.2' "$WORKSPACE/memory/cerebellum-state.json" >/dev/null

echo "PASS: cerebellum forward-model prediction error"
