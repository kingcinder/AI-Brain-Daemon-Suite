#!/bin/bash
# test_proposal_arbitration.sh — Phase 4: executive proposal arbitration.
#
# Validates that arbitrate-proposals.sh:
#   1. Returns empty result when no proposals exist
#   2. Scores goal-aligned proposals higher than misaligned ones
#   3. DA above baseline amplifies goal-aligned proposals
#   4. Cortisol dampens high-risk proposals
#   5. Combined ranking places goal-aligned low-risk proposals at #1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/memory/self-mod/proposals"

PASS=0; FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# ── Helper: create proposal ─────────────────────────────────────────────────
make_prop() {
  local id="$1" module="$2" desc="$3" err="${4:-0.15}" task="${5:-0.6}"
  cat > "$WS/memory/self-mod/proposals/${id}.json" << PROPJSON
{
  "proposal_id": "$id",
  "module": "$module",
  "target_paths": ["skills/${module}/scripts/get-state.sh"],
  "description": "$desc",
  "estimated_components": {
    "task_success": $task,
    "resource_cost": 0.25,
    "error_rate": $err,
    "regression_penalty": 0.05
  },
  "scores": {
    "pre_utility": $task
  },
  "status": "ranked"
}
PROPJSON
}

# ── Test 1: Empty proposals ─────────────────────────────────────────────────
echo "Test 1: No proposals → empty arbitration"
RESULT=$(WORKSPACE="$WS" bash "$ROOT/core/executive/arbitrate-proposals.sh" --workspace "$WS" 2>/dev/null)
COUNT=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "-1")
[ "$COUNT" = "0" ] && pass "empty arbitration returns count=0" || fail "expected count=0, got $COUNT"

# ── Test 2: Goal alignment ─────────────────────────────────────────────────
echo "Test 2: Goal-aligned proposals rank higher"
# Create active PFC goals about memory optimization
cat > "$WS/memory/pfc-state.json" << 'PFC'
{
  "goals": [
    {"description": "Improve memory encoding reliability", "priority": 0.9, "status": "active"},
    {"description": "Reduce daemon heartbeat latency", "priority": 0.5, "status": "active"},
    {"description": "Completed: deploy dashboard", "priority": 0.0, "status": "completed"}
  ]
}
PFC
# Proposal aligned with memory goal
make_prop "prop_mem" "hippocampus-memory" "improve memory encoding reliability in hippocampus"
# Proposal not aligned with any goal
make_prop "prop_misc" "social-memory" "add emoji to social profile display"
RESULT2=$(WORKSPACE="$WS" bash "$ROOT/core/executive/arbitrate-proposals.sh" --workspace "$WS" --top-k 2 2>/dev/null)
TOP2=$(echo "$RESULT2" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['ranked'][0]['proposal_id'])" 2>/dev/null || echo "none")
GA_MEM=$(echo "$RESULT2" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['ranked'][0]['goal_alignment'])" 2>/dev/null || echo "0")
echo "  top=$TOP2 goal_alignment=$GA_MEM"
[ "$TOP2" = "prop_mem" ] && pass "goal-aligned proposal ranks #1" || fail "expected prop_mem at #1, got $TOP2"

# ── Test 3: DA amplification ────────────────────────────────────────────────
echo "Test 3: High DA amplifies goal-aligned proposals"
# Set high DA (0.8)
make_prop "prop_da" "hippocampus-memory" "improve memory encoding reliability"
cat > "$WS/memory/neuromod-state.json" << 'NEUROMOD'
{"modulators": {"dopamine": {"value": 0.8}, "cortisol": {"value": 0.3}}}
NEUROMOD
RESULT3=$(WORKSPACE="$WS" bash "$ROOT/core/executive/arbitrate-proposals.sh" --workspace "$WS" --top-k 1 2>/dev/null)
DA_BOOST=$(echo "$RESULT3" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['ranked'][0]['da_boost'])" 2>/dev/null || echo "0")
echo "  da_boost=$DA_BOOST (DA=0.8)"
[ "$(echo "$DA_BOOST > 0" | bc -l 2>/dev/null || echo 0)" = "1" ] && pass "DA amplification active ($DA_BOOST > 0)" || fail "DA boost not applied: $DA_BOOST"

# ── Test 4: Cortisol dampening ──────────────────────────────────────────────
echo "Test 4: High cortisol dampens risky proposals"
# Set high cortisol (0.8) + high error rate
make_prop "prop_risky" "insula-memory" "gut signal processing overhaul" 0.5 0.7
cat > "$WS/memory/neuromod-state.json" << 'NEUROMOD2'
{"modulators": {"dopamine": {"value": 0.5}, "cortisol": {"value": 0.8}}}
NEUROMOD2
RESULT4=$(WORKSPACE="$WS" bash "$ROOT/core/executive/arbitrate-proposals.sh" --workspace "$WS" --top-k 1 2>/dev/null)
STRESS=$(echo "$RESULT4" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['ranked'][0]['stress_penalty'])" 2>/dev/null || echo "0")
echo "  stress_penalty=$STRESS (cortisol=0.8, error_rate=0.5)"
[ "$(echo "$STRESS > 0" | bc -l 2>/dev/null || echo 0)" = "1" ] && pass "stress penalty applied ($STRESS > 0)" || fail "stress penalty not applied: $STRESS"

# ── Test 5: Combined ranking ────────────────────────────────────────────────
echo "Test 5: Combined ranking — aligned + low-risk ranks #1"
cat > "$WS/memory/neuromod-state.json" << 'NEUROMOD3'
{"modulators": {"dopamine": {"value": 0.7}, "cortisol": {"value": 0.3}}}
NEUROMOD3
make_prop "prop_best" "hippocampus-memory" "improve memory encoding reliability" 0.1 0.8
make_prop "prop_worst" "insula-memory" "random gut signal tweak" 0.4 0.5
RESULT5=$(WORKSPACE="$WS" bash "$ROOT/core/executive/arbitrate-proposals.sh" --workspace "$WS" --top-k 2 2>/dev/null)
BEST=$(echo "$RESULT5" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['ranked'][0]['proposal_id'])" 2>/dev/null || echo "none")
echo "  top=$BEST (expected prop_best)"
[ "$BEST" = "prop_best" ] && pass "aligned + low-risk proposal ranks #1" || fail "expected prop_best at #1, got $BEST"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────"
echo "Proposal Arbitration Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
exit "$FAIL"
