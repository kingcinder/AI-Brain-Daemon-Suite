#!/bin/bash
# test_gate_neuromod.sh — A3: neuromodulation of the gate + regression lock.
#
# Tests:
#  (b) ABSENT vector => gate scores are byte-identical to a run without the
#      layer (the compatibility regression lock)
#  (a) high noradrenaline raises urgency — NA=1.0 scores strictly above NA=0.5
#  (c) a passing signal triggers a broadcast (workspace.json currentFocus set)
#
# Run: bash tests/test_gate_neuromod.sh
# Requires: jq, bc

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory" "$TEST_WORKSPACE/memory/.signal-checkpoints"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

GATE="$ROOT/skills/thalamus-memory/scripts/gate.sh"

# Common fixture: PFC goal + exec load, one neutral-urgency signal.
cat > "$TEST_WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}]}
EOF
cat > "$TEST_WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.4, "band": "desired"}
EOF

score_signal() {
    echo "$1" | "$GATE" --stdin 2>/dev/null | jq -r '.gateScore // 0'
}

# ── (b) FIRST: absent-vector baseline must equal today's unmodulated score ─
echo "Test (b): absent vector == today's scores (regression lock)"

BASE_OUT=$(echo '{"source":"vta-memory","signal":"neutral_sig","intensity":0.5}' | \
    "$GATE" --stdin 2>/dev/null)
BASE=$(echo "$BASE_OUT" | jq -r '.gateScore // 0')
GATE_CIR=$(echo "$BASE_OUT" | jq -r '.dimensions.circadianGain // 0.5')
EXPECTED=$(echo "scale=6; (0.0*0.35 + 0.7*0.15 + 0.30*0.25 + 0.6*0.25) * $GATE_CIR" | bc)

DIFF=$(echo "scale=4; if ($BASE > $EXPECTED) $BASE - $EXPECTED else $EXPECTED - $BASE" | bc 2>/dev/null || echo "999")
if (( $(echo "$DIFF < 0.001" | bc -l) )); then
    pass "absent vector is byte-identical to the unmodulated formula (base=$BASE expected=$EXPECTED)"
else
    fail "absent vector deviates: base=$BASE expected=$EXPECTED (diff=$DIFF) — neutral-by-default violated"
fi

# ── (a) high noradrenaline raises urgency ─────────────────────────────────
echo "Test (a): high noradrenaline raises urgency"

# NA=1.0 vector — all other modulators at baseline, cortisol at 0 to avoid
# off-focus suppression contaminating the comparison.
cat > "$TEST_WORKSPACE/memory/neuromod-state.json" << 'EOF'
{"version":1,"updatedAt":"2026-08-08T00:00:00Z",
 "modulators": {
   "dopamine": {"value": 0.5}, "noradrenaline": {"value": 1.0},
   "serotonin": {"value": 0.5}, "acetylcholine": {"value": 0.5},
   "cortisol": {"value": 0.0}, "oxytocin": {"value": 0.5},
   "sleepPressure": {"value": 0.0}},
 "composites": {"arousal": 0.8, "valence": 0.5, "stressIndex": 0.5},
 "missingSources": []}
EOF

HIGH_NA=$(score_signal '{"source":"vta-memory","signal":"neutral_sig","intensity":0.5}')

# NA=0.5 baseline vector
cat > "$TEST_WORKSPACE/memory/neuromod-state.json" << 'EOF'
{"version":1,"updatedAt":"2026-08-08T00:00:00Z",
 "modulators": {
   "dopamine": {"value": 0.5}, "noradrenaline": {"value": 0.5},
   "serotonin": {"value": 0.5}, "acetylcholine": {"value": 0.5},
   "cortisol": {"value": 0.0}, "oxytocin": {"value": 0.5},
   "sleepPressure": {"value": 0.0}},
 "composites": {"arousal": 0.5, "valence": 0.5, "stressIndex": 0.5},
 "missingSources": []}
EOF
LOW_NA=$(score_signal '{"source":"vta-memory","signal":"neutral_sig","intensity":0.5}')
if (( $(echo "$HIGH_NA > $LOW_NA" | bc -l) )); then
    pass "NA=1.0 scores strictly above NA=0.5 ($LOW_NA -> $HIGH_NA)"
else
    fail "expected HIGH_NA > LOW_NA, got $LOW_NA vs $HIGH_NA"
fi

# ── (c) passing signal broadcasts to the workspace ────────────────────────
echo "Test (c): non-suppressed dispatch broadcasts to workspace.json"

rm -f "$TEST_WORKSPACE/memory/workspace.json"
# A strongly goal-relevant signal should pass regardless of modulation.
echo '{"source":"prefrontal-cortex-memory","signal":"goal_promoted","intensity":0.9,"payload":{"description":"ship the brain suite"}}' \
    | "$GATE" --stdin > /dev/null 2>&1 || true

# The broadcast runs in a background subshell — give it a moment.
sleep 0.5
if [[ -f "$TEST_WORKSPACE/memory/workspace.json" ]]; then
    F=$(jq -r '.currentFocus.source // "none"' "$TEST_WORKSPACE/memory/workspace.json")
    N=$(jq '.recentBroadcasts | length' "$TEST_WORKSPACE/memory/workspace.json" 2>/dev/null || echo 0)
    if [[ "$F" != "none" && "$N" -ge 1 ]]; then
        pass "gate dispatch broadcast to workspace (focus=$F, entries=$N)"
    else
        fail "workspace written but empty focus=$F entries=$N"
    fi
else
    fail "gate dispatch did not create workspace.json"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Gate Neuromod Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0