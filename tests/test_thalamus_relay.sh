#!/bin/bash
# test_thalamus_relay.sh — Unit tests for the bidirectional cortico-thalamo-
# cortical relay added to gate.sh.
#
# The relay closes the loop the gate previously lacked (the last PARTIAL-by-
# structure verdict from NEUROSCIENCE_MAPPING.md):
#   feedforward: signal → gate scores + dispatches to cortex, tallied in
#                relay.stats (the driving thalamo-cortical path)
#   feedback:    cortical attend/release directives modulate the gate's
#                attentionFocus and per-channel gain (the layer-6 / TRN
#                top-down path) — a signal matching an attend target is
#                amplified by (1.0 + 0.5×weight)
#
# Tests:
#  (1) regression lock — empty relay == unmodulated formula score
#      (byte-identical, neutral-by-default)
#  (2) feedforward leg records relay bookkeeping (stats.feedforward, lastLoopAt)
#  (3) feedback leg: attend directive → attentionFocus + relay.feedback +
#      relay.stats.feedback
#  (4) the loop closes: an attended signal scores strictly ABOVE its baseline
#      while a non-attended channel is unchanged (no cross-channel bleed)
#  (5) release stands the loop down: focus cleared, feedback cleared, score
#      returns to the pre-attend baseline
#
# Run: bash tests/test_thalamus_relay.sh
# Requires: jq, bc (both in the Suite's existing dependency set)

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
STATE="$TEST_WORKSPACE/memory/thalamus-state.json"

# Fixture: PFC goal + exec load (same neutral-urgency setup as test_gate_neuromod.sh)
cat > "$TEST_WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}]}
EOF
cat > "$TEST_WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.4, "band": "desired"}
EOF

score_signal() {
    echo "$1" | "$GATE" --stdin 2>/dev/null | jq -r '.gateScore // 0'
}

# The gate's novelty factor counts how many times this source+signal was
# recently suppressed (suppressedQueue): a fresh signal scores novelty 0.7,
# but each suppressed repeat drops it 0.7 → 0.5 → 0.3. Repeating the same
# fixture signal across tests would accumulate queue entries and silently
# change the unmodulated score mid-test — so a cross-call comparison could
# fail even though the relay did nothing wrong. Reset the queue before every
# measurement so novelty is constant (0.7) and only the relay's effect moves
# the score.
reset_queue() {
    jq '.suppressedQueue = []' "$STATE" > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE" || true
}

# Normalized score: gateScore / circadianGain, so cross-call comparisons are
# immune to the hour boundary flipping the circadian gain mid-test (the ci-gate
# run that crossed 22:00 UTC exposed this — gain dropped 1.0 → 0.5 between two
# calls and the "attended scores above baseline" assertion failed spuriously).
score_norm() {
    reset_queue
    echo "$1" | "$GATE" --stdin 2>/dev/null | jq -r '.gateScore / .dimensions.circadianGain'
}

# Absolute difference of two bc numbers.
absdiff() {
    echo "scale=4; if ($1 > $2) $1 - $2 else $2 - $1" | bc 2>/dev/null || echo "999"
}

# ── (1) FIRST: empty relay must equal the unmodulated formula ──────────────
echo "Test 1: empty relay == today's unmodulated score (regression lock)"

BASE_OUT=$(echo '{"source":"vta-memory","signal":"relay_neutral","intensity":0.5}' | \
    "$GATE" --stdin 2>/dev/null)
BASE=$(echo "$BASE_OUT" | jq -r '.gateScore // 0')
GATE_CIR=$(echo "$BASE_OUT" | jq -r '.dimensions.circadianGain // 0.5')
EXPECTED=$(echo "scale=6; (0.0*0.35 + 0.7*0.15 + 0.30*0.25 + 0.6*0.25) * $GATE_CIR" | bc)

DIFF=$(absdiff "$BASE" "$EXPECTED")
if (( $(echo "$DIFF < 0.001" | bc -l) )); then
    pass "empty relay is byte-identical to the unmodulated formula (base=$BASE expected=$EXPECTED)"
else
    fail "empty relay deviates: base=$BASE expected=$EXPECTED (diff=$DIFF) — neutral-by-default violated"
fi

# ── (2) feedforward leg records relay bookkeeping ──────────────────────────
echo "Test 2: feedforward leg records relay bookkeeping"

FF=$(jq -r '.relay.stats.feedforward // 0' "$STATE" 2>/dev/null || echo "0")
if [[ "${FF:-0}" -ge 1 ]]; then
    pass "feedforward leg increments relay.stats.feedforward ($FF)"
else
    fail "relay.stats.feedforward not recorded (got $FF)"
fi

LL=$(jq -r '.relay.stats.lastLoopAt // ""' "$STATE" 2>/dev/null || echo "")
if [[ -n "$LL" ]]; then
    pass "feedforward leg timestamps the loop (lastLoopAt=$LL)"
else
    fail "relay.stats.lastLoopAt not set"
fi

# ── (3) feedback leg: attend directive modulates the gate ──────────────────
echo "Test 3: feedback leg — attend directive is applied"

# Capture both channels' pre-attend baselines BEFORE any feedback.
# (score_norm: hour-immune — circadian gain divided out of each call, so a
# cross-call comparison can never mix raw and normalized scores.)
AMY_BASE=$(score_norm '{"source":"amygdala-memory","signal":"salient_event","intensity":0.5}')
VTA_BASE=$(score_norm '{"source":"vta-memory","signal":"relay_neutral","intensity":0.5}')

"$GATE" --feedback attend amygdala-memory --weight 0.8 --from prefrontal-cortex-memory > /dev/null 2>&1

INFOCUS=$(jq -r '.attentionFocus | index("amygdala-memory") != null' "$STATE" 2>/dev/null || echo "false")
if [[ "$INFOCUS" = "true" ]]; then
    pass "attend adds the target to attentionFocus"
else
    fail "attentionFocus missing the attended target"
fi

FBW=$(jq -r '[.relay.feedback[]? | select(.kind == "attend" and .target == "amygdala-memory") | .weight] | if length > 0 then .[0] else "0" end' "$STATE" 2>/dev/null || echo "0")
if [[ "$FBW" = "0.8" ]]; then
    pass "relay.feedback records the attend weight (0.8)"
else
    fail "relay.feedback weight wrong (got $FBW)"
fi

FBFROM=$(jq -r '[.relay.feedback[]? | select(.target == "amygdala-memory") | .from] | if length > 0 then .[0] else "" end' "$STATE" 2>/dev/null || echo "")
if [[ "$FBFROM" = "prefrontal-cortex-memory" ]]; then
    pass "relay.feedback records the issuing cortex skill (provenance)"
else
    fail "relay.feedback provenance wrong (got '$FBFROM')"
fi

FBC=$(jq -r '.relay.stats.feedback // 0' "$STATE" 2>/dev/null || echo "0")
if [[ "${FBC:-0}" -ge 1 ]]; then
    pass "feedback leg increments relay.stats.feedback ($FBC)"
else
    fail "relay.stats.feedback not incremented"
fi

# ── (4) the loop closes: attended channel amplified, others untouched ──────
echo "Test 4: the loop closes — top-down gain on the attended channel"

AMY_AMP=$(score_norm '{"source":"amygdala-memory","signal":"salient_event","intensity":0.5}')
if (( $(echo "$AMY_AMP > $AMY_BASE" | bc -l) )); then
    pass "attended signal scores strictly above its baseline ($AMY_BASE -> $AMY_AMP)"
else
    fail "expected amplification, got $AMY_BASE -> $AMY_AMP"
fi

# The non-attended channel must be unchanged — no cross-channel bleed.
# Compared against its own normalized pre-attend baseline (NOT the raw Test-1
# $BASE, which is same-call-only and would mix scales across an hour boundary).
VTA_AFTER=$(score_norm '{"source":"vta-memory","signal":"relay_neutral","intensity":0.5}')
D2=$(absdiff "$VTA_AFTER" "$VTA_BASE")
if (( $(echo "$D2 < 0.0005" | bc -l) )); then
    pass "non-attended channel unchanged (vta $VTA_BASE -> $VTA_AFTER)"
else
    fail "cross-channel bleed: vta $VTA_BASE -> $VTA_AFTER after attending amygdala"
fi

# ── (5) validation: bad directives are rejected ───────────────────────────
echo "Test 5: malformed feedback directives are rejected"

if "$GATE" --feedback attend > /dev/null 2>&1; then
    fail "--feedback without a target should exit non-zero"
else
    pass "--feedback without a target is rejected"
fi

if "$GATE" --feedback bogus some_target > /dev/null 2>&1; then
    fail "unknown feedback kind should exit non-zero"
else
    pass "unknown feedback kind is rejected"
fi

if "$GATE" --feedback attend some_target --weight banana > /dev/null 2>&1; then
    fail "non-numeric --weight should exit non-zero"
else
    pass "non-numeric --weight is rejected"
fi

# ── (6) release stands the loop down ───────────────────────────────────────
echo "Test 6: release stands the loop down"

"$GATE" --feedback release amygdala-memory > /dev/null 2>&1

INFOCUS2=$(jq -r '.attentionFocus | index("amygdala-memory") != null' "$STATE" 2>/dev/null || echo "true")
if [[ "$INFOCUS2" = "false" ]]; then
    pass "release removes the target from attentionFocus"
else
    fail "attentionFocus still contains the released target"
fi

FBN=$(jq -r '[.relay.feedback[]? | select(.target == "amygdala-memory")] | length' "$STATE" 2>/dev/null || echo "1")
if [[ "${FBN:-1}" -eq 0 ]]; then
    pass "release clears the relay feedback entry"
else
    fail "relay.feedback still has the entry (count=$FBN)"
fi

AMY_AFTER_RELEASE=$(score_norm '{"source":"amygdala-memory","signal":"salient_event","intensity":0.5}')
D3=$(absdiff "$AMY_AFTER_RELEASE" "$AMY_BASE")
if (( $(echo "$D3 < 0.0005" | bc -l) )); then
    pass "released channel returns to its pre-attend baseline ($AMY_BASE -> $AMY_AFTER_RELEASE)"
else
    fail "released channel did not return to baseline: $AMY_BASE -> $AMY_AFTER_RELEASE"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Thalamus Relay Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
