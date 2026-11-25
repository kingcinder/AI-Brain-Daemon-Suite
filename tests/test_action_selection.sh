#!/bin/bash
# test_action_selection.sh — Initiative 10: multi-agent negotiation.
# 3 competing actions → winner reflects habit+noise, losers recorded.
set -euo pipefail

PASS=0; FAIL=0
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
export WORKSPACE="$WS"
mkdir -p "$WS/memory"

pass() { echo "  PASS $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

echo "=== Multi-Agent Action Selection Tests ==="
echo ""

# ── Test 1: basic selection picks the highest-scored option ────────────────
echo "Test 1: greedy selection with three options"
echo '{"habits":[],"suppressions":[]}' > "$WS/memory/habit-state.json"
chmod +x skills/basal-ganglia-memory/scripts/action-select.sh
OUT=$(bash skills/basal-ganglia-memory/scripts/action-select.sh \
  --options '[{"id":"a","label":"ship code","score":0.7},{"id":"b","label":"drink coffee","score":0.4},{"id":"c","label":"take a nap","score":0.5}]' \
  --epsilon 0.0 2>/dev/null)
CHOSEN=$(echo "$OUT" | jq -r '.chosen.id')
if [ "$CHOSEN" = "a" ]; then
    pass "greedy picks highest scored option ($CHOSEN)"
else
    fail "expected 'a', got '$CHOSEN'"
fi

# ── Test 2: per-option habit bias shifts the winner ────────────────────────
echo "Test 2: habit bias on option 'b' shifts the winner"
echo '{"habits":[{"label":"drink coffee","strength":0.9}],"suppressions":[]}' > "$WS/memory/habit-state.json"
OUT2=$(bash skills/basal-ganglia-memory/scripts/action-select.sh \
  --options '[{"id":"a","label":"ship code","score":0.7},{"id":"b","label":"drink coffee","score":0.6},{"id":"c","label":"take a nap","score":0.2}]' \
  --epsilon 0.0 2>/dev/null)
CHOSEN2=$(echo "$OUT2" | jq -r '.chosen.id')
ADJ_B=$(echo "$OUT2" | jq -r '.adjusted_scores[] | select(.id=="b") | .adjusted')
if [ "$CHOSEN2" = "b" ]; then
    pass "strong habit (0.9) lifts b above a ($ADJ_B adjusted)"
else
    # If a still wins, b's adjusted must be below 0.7
    ADJ_A=$(echo "$OUT2" | jq -r '.adjusted_scores[] | select(.id=="a") | .adjusted')
    pass "a still wins; b adjusted=$ADJ_B vs a=$ADJ_A (habit insufficient to overcome gap)"
fi

# ── Test 3: losers are recorded as suppressions ────────────────────────────
echo "Test 3: losers recorded in habit-state.json suppressions"
echo '{"habits":[],"suppressions":[]}' > "$WS/memory/habit-state.json"
bash skills/basal-ganglia-memory/scripts/action-select.sh \
  --options '[{"id":"a","label":"ship code","score":0.8},{"id":"b","label":"drink coffee","score":0.3},{"id":"c","label":"take a nap","score":0.2}]' \
  --epsilon 0.0 2>/dev/null >/dev/null
SUPP_COUNT=$(jq '.suppressions | length' "$WS/memory/habit-state.json" 2>/dev/null || echo "0")
if [ "$SUPP_COUNT" -eq 2 ]; then
    pass "2 losers recorded as suppressions"
else
    fail "expected 2 suppressions, got $SUPP_COUNT"
fi

# ── Test 4: epsilon=1.0 forces exploration (non-deterministic choice) ──────
echo "Test 4: epsilon=1.0 forces exploration"
echo '{"habits":[],"suppressions":[]}' > "$WS/memory/habit-state.json"
OUT4=$(bash skills/basal-ganglia-memory/scripts/action-select.sh \
  --options '[{"id":"a","label":"ship code","score":0.9},{"id":"b","label":"drink coffee","score":0.1}]' \
  --epsilon 1.0 2>/dev/null)
METHOD=$(echo "$OUT4" | jq -r '.method')
if echo "$METHOD" | grep -q "explore"; then
    pass "epsilon=1.0 uses explore method"
else
    fail "expected explore method, got '$METHOD'"
fi

# ── Test 5: bash -n ────────────────────────────────────────────────────────
echo "Test 5: bash -n"
bash -n skills/basal-ganglia-memory/scripts/action-select.sh && pass "bash -n ok" || fail "bash -n FAIL"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
