#!/bin/bash
# test_thalamus_gate.sh — Unit tests for the thalamus signaling infrastructure.
#
# Tests:
#  1. publish.sh emits valid JSON to brain-signals.jsonl
#  2. subscribe.sh correctly filters and watermarks
#  3. gate.sh scores signals across all five dimensions
#  4. route-signals.sh produces correct routing table
#  5. signal-daemon.sh processes signals end-to-end
#  6. attention-filter.sh standalone scoring
#
# Run: bash tests/test_thalamus_gate.sh
# Requires: jq, bc (both in the Suite's existing dependency set)

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Setup test workspace
mkdir -p "$TEST_WORKSPACE/memory" "$TEST_WORKSPACE/memory/.signal-checkpoints"

# ── Utility ─────────────────────────────────────────────────────────────
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── Test 1: publish.sh emits valid JSON ─────────────────────────────────
echo "Test 1: publish.sh emits valid JSON signal"

"$ROOT/core/signaling/publish.sh" \
    --type "emotional" \
    --source "amygdala-memory" \
    --signal "positive_state" \
    --intensity 0.7 \
    --payload '{"emotion":"joy"}'

SIGNAL_LOG="$TEST_WORKSPACE/memory/brain-signals.jsonl"
if [[ -f "$SIGNAL_LOG" ]]; then
    LINE_COUNT=$(wc -l < "$SIGNAL_LOG")
    if [[ "$LINE_COUNT" -ge 1 ]]; then
        LAST=$(tail -1 "$SIGNAL_LOG")
        SOURCE=$(echo "$LAST" | jq -r '.source')
        SIGNAL=$(echo "$LAST" | jq -r '.signal')
        INTENSITY=$(echo "$LAST" | jq -r '.intensity')
        if [[ "$SOURCE" = "amygdala-memory" && "$SIGNAL" = "positive_state" && "$INTENSITY" = "0.7" ]]; then
            pass "Signal emitted correctly by publish.sh"
        else
            fail "Signal has wrong values: source=$SOURCE signal=$SIGNAL intensity=$INTENSITY"
        fi
    else
        fail "Signal log has zero lines"
    fi
else
    fail "Signal log not created"
fi

# ── Test 2: publish.sh without required args fails ──────────────────────
echo "Test 2: publish.sh rejects missing required args"

if "$ROOT/core/signaling/publish.sh" --type "test" 2>/dev/null; then
    fail "publish.sh should exit non-zero without --source and --signal"
else
    pass "publish.sh correctly rejects missing args"
fi

# ── Test 3: subscribe.sh polling and watermarking ───────────────────────
echo "Test 3: subscribe.sh polls and watermarks correctly"

# Publish another signal
"$ROOT/core/signaling/publish.sh" \
    --type "correction" \
    --source "acc-error-memory" \
    --signal "critical_pattern" \
    --intensity 0.9

# Subscribe without advancing
RESULT=$("$ROOT/core/signaling/subscribe.sh" --subscriber "test-sub" 2>/dev/null || true)
if echo "$RESULT" | jq -e '.signal == "positive_state" or .signal == "critical_pattern"' > /dev/null 2>&1; then
    pass "subscribe.sh returns matching signals"
else
    fail "subscribe.sh returned unexpected results: $RESULT"
fi

# Advance watermark, then check nothing new
"$ROOT/core/signaling/subscribe.sh" --subscriber "test-sub" --advance > /dev/null 2>&1
RESULT2=$("$ROOT/core/signaling/subscribe.sh" --subscriber "test-sub" 2>/dev/null || true)
if [[ -z "$RESULT2" ]]; then
    pass "subscribe.sh watermark prevents re-reading"
else
    fail "subscribe.sh should return nothing after advancing watermark"
fi

# ── Test 4: route-signals.sh returns valid routing table ────────────────
echo "Test 4: route-signals.sh returns valid routing table"

ROUTES=$("$ROOT/core/signaling/route-signals.sh" 2>/dev/null || true)
ROUTE_COUNT=$(echo "$ROUTES" | wc -l)
if [[ "$ROUTE_COUNT" -ge 5 ]]; then
    # Check for a known route
    if echo "$ROUTES" | grep -q "amygdala-memory.*positive_state.*vta-memory"; then
        pass "route-signals.sh contains expected amygdala→vta route"
    else
        fail "route-signals.sh missing expected amygdala→vta route"
    fi
    # Verification region (proprioception): inbound + outbound routes
    if echo "$ROUTES" | grep -q "verification-memory.*tests_passed.*vta-memory" && \
       echo "$ROUTES" | grep -q "verification-memory.*test_failure.*acc-error-memory" && \
       echo "$ROUTES" | grep -q "prefrontal-cortex-memory.*goal_promoted.*verification-memory"; then
        pass "route-signals.sh contains verification-memory inbound + outbound routes"
    else
        fail "route-signals.sh missing verification-memory routes"
    fi
else
    fail "route-signals.sh has too few routes ($ROUTE_COUNT)"
fi

# ── Test 5: attention-filter.sh standalone scoring ─────────────────────
echo "Test 5: attention-filter.sh scores signals"

# Create a minimal PFC state with an active goal
mkdir -p "$TEST_WORKSPACE/memory"
cat > "$TEST_WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}]}
EOF

# Create executive load state
cat > "$TEST_WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.4, "band": "desired"}
EOF

# Pipe a signal into attention-filter
echo '{"source":"amygdala-memory","signal":"positive_state","intensity":0.7}' | \
    "$ROOT/skills/thalamus-memory/scripts/attention-filter.sh" > "$TEST_WORKSPACE/filter-result.json" 2>/dev/null

if [[ -f "$TEST_WORKSPACE/filter-result.json" ]]; then
    ACTION=$(jq -r '.action' "$TEST_WORKSPACE/filter-result.json")
    SCORE=$(jq -r '.gateScore' "$TEST_WORKSPACE/filter-result.json")
    GOALREL=$(jq -r '.dimensions.goalRelevance' "$TEST_WORKSPACE/filter-result.json")
    if [[ -n "$ACTION" && -n "$SCORE" ]]; then
        pass "attention-filter.sh returns valid scored result (action=$ACTION score=$SCORE)"
    else
        fail "attention-filter.sh result missing action or score"
    fi
else
    fail "attention-filter.sh produced no output"
fi

# ── Test 6: gate.sh --status works ─────────────────────────────────────
echo "Test 6: gate.sh --status displays state"

# Initialize thalamus state
"$ROOT/skills/thalamus-memory/scripts/gate.sh" --process > /dev/null 2>&1 || true

STATUS_OUT=$("$ROOT/skills/thalamus-memory/scripts/gate.sh" --status 2>/dev/null || true)
if echo "$STATUS_OUT" | grep -q "Thalamus Attention Gate"; then
    pass "gate.sh --status displays human-readable state"
else
    fail "gate.sh --status output missing expected header"
fi

# ── Test 7: gate.sh --process handles signals ───────────────────────────
echo "Test 7: gate.sh --process processes signals"

# Publish a signal that should be routed (amygdala → vta)
"$ROOT/core/signaling/publish.sh" \
    --type "emotional" \
    --source "amygdala-memory" \
    --signal "positive_state" \
    --intensity 0.8

# Run gate in process mode
"$ROOT/skills/thalamus-memory/scripts/gate.sh" --process > /dev/null 2>&1 || true

# Check stats were updated
if [[ -f "$TEST_WORKSPACE/memory/thalamus-state.json" ]]; then
    TOTAL=$(jq -r '.stats.totalSignalsProcessed // 0' "$TEST_WORKSPACE/memory/thalamus-state.json" 2>/dev/null || echo "0")
    if [[ "${TOTAL:-0}" -ge 1 ]]; then
        pass "gate.sh --process updates signal processing stats (total=$TOTAL)"
    else
        fail "gate.sh --process did not update stats (total=$TOTAL)"
    fi
else
    fail "thalamus-state.json not created by gate.sh"
fi

# ── Test 8: signal-daemon.sh --once processes end-to-end ────────────────
echo "Test 8: signal-daemon.sh --once processes end-to-end"

# Run the signal daemon once
"$ROOT/core/signaling/signal-daemon.sh" --once > /dev/null 2>&1 || true

# Should not crash, should advance checkpoint
if [[ -f "$TEST_WORKSPACE/memory/.signal-checkpoints/signal-daemon" ]]; then
    pass "signal-daemon.sh --once advances checkpoint"
else
    fail "signal-daemon.sh --once did not create checkpoint"
fi

# ── Test 9: thalamus decay.sh manages suppressed queue ──────────────────
echo "Test 9: thalamus decay.sh manages suppressed queue"

# Manually add a suppressed signal to the state
cat > "$TEST_WORKSPACE/memory/thalamus-state.json" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "",
  "attentionFocus": [],
  "suppressedQueue": [
    {"signal":{"source":"test","signal":"old_signal"},"suppressedAt":"2020-01-01T00:00:00Z","retryAfter":"2020-01-01T01:00:00Z","reason":"test"},
    {"signal":{"source":"test","signal":"future_signal"},"suppressedAt":"2099-01-01T00:00:00Z","retryAfter":"2099-01-02T00:00:00Z","reason":"test"}
  ],
  "stats": {"totalSignalsProcessed":0,"amplified":0,"passed":0,"attenuated":0,"suppressed":2,"dispatchedToTargets":0},
  "gateSensitivity": 0.5,
  "lastGateRun": ""
}
EOF

"$ROOT/skills/thalamus-memory/scripts/decay.sh" > /dev/null 2>&1 || true

REMAINING=$(jq -r '.suppressedQueue | length // 0' "$TEST_WORKSPACE/memory/thalamus-state.json" 2>/dev/null || echo "0")
if [[ "${REMAINING:-0}" -eq 1 ]]; then
    pass "thalamus decay.sh removes expired suppressed signals"
else
    fail "thalamus decay.sh should leave 1 signal, got $REMAINING"
fi

# The retry contract: the expired signal is re-injected into the signal bus
# (re-scored on the next gate run), not silently dropped.
REINJECTED=$(grep -c 'thalamus_retry' "$TEST_WORKSPACE/memory/brain-signals.jsonl" 2>/dev/null || echo "0")
if [[ "${REINJECTED:-0}" -ge 1 ]]; then
    pass "thalamus decay.sh re-injects expired signals into the signal bus"
else
    fail "thalamus decay.sh should re-inject the expired signal (got $REINJECTED retry lines)"
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Thalamus Signaling Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
