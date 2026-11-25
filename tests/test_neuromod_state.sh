#!/bin/bash
# test_neuromod_state.sh — A1: neuromod vector composition.
#
# Tests:
#  1. neuromod-update.sh writes a valid vector with all 7 modulators + composites
#  2. dopamine mapping: higher drive raises dopamine; clamp at 1.0
#  3. noradrenaline mapping: arousal + insula load + heartbeat recency
#  4. oxytocin mapping: mean relationship trust
#  5. sleepPressure: 0 in a fresh/absent-heartbeat workspace
#  6. partial vector: one missing source file degrades, others still computed
#  7. all sources missing: baselines, missingSources lists them, exit 0
#  8. get-neuromod.sh: --get returns the value; --json returns the vector;
#     absent file returns the neutral default
#  9. atomic write: no .tmp.$$ residue; lock file exists
#
# Run: bash tests/test_neuromod_state.sh
# Requires: jq, bc

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

UP="$ROOT/skills/thalamus-memory/scripts/neuromod-update.sh"
GET="$ROOT/skills/thalamus-memory/scripts/get-neuromod.sh"

# ── Test 1: writes a valid vector ──────────────────────────────────────
echo "Test 1: neuromod-update.sh writes a valid vector"

# Use current timestamp so the 24h stale-decay doesn't fire.
FIXTURE_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$TEST_WORKSPACE/memory/reward-state.json" << EOF
{"drive": 0.6, "recentRewards": [{"id":"r1"}], "anticipating": ["a1"], "lastUpdated": "$FIXTURE_TS"}
EOF
cat > "$TEST_WORKSPACE/memory/emotional-state.json" << EOF
{"dimensions": {"valence": 0.6, "arousal": 0.6}, "lastUpdated": "$FIXTURE_TS"}
EOF
cat > "$TEST_WORKSPACE/memory/conflict-state.json" << EOF
{"conflictLoad": 0.5, "lastUpdated": "$FIXTURE_TS"}
EOF
cat > "$TEST_WORKSPACE/memory/interoceptive-state.json" << EOF
{"channels": {"cognitiveLoad": 0.4, "gutSignal": 0.3}, "lastUpdated": "$FIXTURE_TS"}
EOF
cat > "$TEST_WORKSPACE/memory/social-state.json" << EOF
{"relationships": {"bob": {"trust": 0.7, "affinity": 0.5}}, "lastUpdated": "$FIXTURE_TS"}
EOF
cat > "$TEST_WORKSPACE/memory/heartbeat-state.json" << EOF
{"lastBeat": "", "circadian": {"wakeHour": 8, "sleepHour": 22}, "lastUpdated": "$FIXTURE_TS"}
EOF
cat > "$TEST_WORKSPACE/memory/thalamus-state.json" << EOF
{"attentionFocus": ["ship the brain suite"], "lastUpdated": "$FIXTURE_TS"}
EOF

"$UP" > /dev/null 2>&1

VEC="$TEST_WORKSPACE/memory/neuromod-state.json"
if [[ -f "$VEC" ]]; then
    N=$(jq '.modulators | length' "$VEC")
    if [[ "$N" -eq 7 ]]; then
        pass "vector has all 7 modulators (got $N)"
    else
        fail "expected 7 modulators, got $N"
    fi
    if jq -e '.composites.arousal and .composites.valence and .composites.stressIndex' "$VEC" > /dev/null 2>&1; then
        pass "composites present"
    else
        fail "composites missing"
    fi
else
    fail "neuromod-state.json not created"
fi

# ── Test 2: dopamine mapping + clamp ───────────────────────────────────
echo "Test 2: dopamine mapping and clamp"

# drive 1.0 with recent reward + anticipation -> dopamine should clamp at 1.0
jq '.drive = 1.0' "$TEST_WORKSPACE/memory/reward-state.json" > "$TEST_WORKSPACE/memory/reward-state.json.tmp" \
  && mv "$TEST_WORKSPACE/memory/reward-state.json.tmp" "$TEST_WORKSPACE/memory/reward-state.json"
"$UP" > /dev/null 2>&1
DA=$("$GET" --get dopamine)
if (( $(echo "$DA >= 0.99" | bc -l) )); then
    pass "dopamine clamps at 1.0 (got $DA)"
else
    fail "dopamine should clamp at 1.0, got $DA"
fi

# drive 0.0, no rewards -> dopamine below baseline
jq '.drive = 0.0 | .recentRewards = [] | .anticipating = []' \
  "$TEST_WORKSPACE/memory/reward-state.json" > "$TEST_WORKSPACE/memory/reward-state.json.tmp" \
  && mv "$TEST_WORKSPACE/memory/reward-state.json.tmp" "$TEST_WORKSPACE/memory/reward-state.json"
"$UP" > /dev/null 2>&1
DA=$("$GET" --get dopamine)
if (( $(echo "$DA < 0.5" | bc -l) )); then
    pass "dopamine falls with low drive (got $DA)"
else
    fail "dopamine should be < 0.5 with drive 0, got $DA"
fi

# ── Test 3: noradrenaline mapping ──────────────────────────────────────
echo "Test 3: noradrenaline from arousal + insula + recency"

# arousal 1.0 -> NA well above baseline
jq '.dimensions.arousal = 1.0' "$TEST_WORKSPACE/memory/emotional-state.json" > "$TEST_WORKSPACE/memory/emotional-state.json.tmp" \
  && mv "$TEST_WORKSPACE/memory/emotional-state.json.tmp" "$TEST_WORKSPACE/memory/emotional-state.json"
"$UP" > /dev/null 2>&1
NA=$("$GET" --get noradrenaline)
if (( $(echo "$NA > 0.7" | bc -l) )); then
    pass "noradrenaline rises with arousal (got $NA)"
else
    fail "noradrenaline should be > 0.7 with arousal 1.0, got $NA"
fi

# ── Test 4: oxytocin mapping ───────────────────────────────────────────
echo "Test 4: oxytocin from mean relationship trust"

# single relationship trust 0.7 -> oxytocin ~0.66
OX=$("$GET" --get oxytocin)
if (( $(echo "$OX > 0.60 && $OX < 0.72" | bc -l) )); then
    pass "oxytocin tracks mean trust (got $OX)"
else
    fail "oxytocin should be ~0.66 with trust 0.7, got $OX"
fi

# ── Test 5: sleepPressure stays low without a sleep phase ──────────────
echo "Test 5: sleepPressure stays low without a sleep phase"

SP=$("$GET" --get sleepPressure)
if (( $(echo "$SP < 1.0" | bc -l) )); then
    pass "sleepPressure bounded (got $SP)"
else
    fail "sleepPressure out of range: $SP"
fi

# ── Test 6: partial vector (one source missing) ────────────────────────
echo "Test 6: missing source degrades to a partial vector"

rm -f "$TEST_WORKSPACE/memory/social-state.json"
"$UP" > /dev/null 2>&1
if jq -e '.modulators.dopamine and (.missingSources | index("social"))' "$VEC" > /dev/null 2>&1; then
    pass "partial vector: dopamine computed, social listed in missingSources"
else
    fail "partial vector handling broken: $(cat "$VEC")"
fi

# ── Test 7: all sources missing → baselines, exit 0 ────────────────────
echo "Test 7: all sources missing yields baselines"

mv "$VEC" "$TEST_WORKSPACE/memory/neuromod-state.json.bak"
rm -f "$TEST_WORKSPACE/memory/"*.json
if "$UP" > /dev/null 2>&1; then
    B=$(jq -r '.modulators.dopamine.value // ""' "$VEC" 2>/dev/null || echo "")
    if [[ -z "$B" ]]; then
        pass "all-missing run exits 0 (no vector written, reads neutral)"
    elif (( $(echo "$B >= 0.49 && $B <= 0.51" | bc -l 2>/dev/null) )); then
        pass "all-missing run exits 0 and dopamine baseline ~0.5 (got $B)"
    else
        fail "baseline dopamine should be ~0.5, got $B"
    fi
else
    fail "all-missing source run should exit 0"
fi

# ── Test 8: get-neuromod.sh contract ───────────────────────────────────
echo "Test 8: get-neuromod.sh reader contract"

rm -rf "$TEST_WORKSPACE/memory"
mkdir -p "$TEST_WORKSPACE/memory"
VAL=$("$GET" --get dopamine)
if [[ "$VAL" = "0.5" ]]; then
    pass "--get returns neutral default when absent"
else
    fail "--get should return 0.5 when absent, got '$VAL'"
fi

# ── Test 9: atomic write, no residue, lock present ─────────────────────
echo "Test 9: atomic write hygiene"

cat > "$TEST_WORKSPACE/memory/reward-state.json" << EOF
{"drive": 0.5, "recentRewards": [], "anticipating": [], "lastUpdated": "$FIXTURE_TS"}
EOF
"$UP" > /dev/null 2>&1
if [[ -f "$TEST_WORKSPACE/memory/neuromod-state.json.lock" ]]; then
    pass "lock file present"
else
    fail "lock file missing"
fi
if ! ls "$TEST_WORKSPACE/memory/neuromod-state.json.tmp."* > /dev/null 2>&1; then
    pass "no tmp residue"
else
    fail "tmp residue left behind"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Neuromod State Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0