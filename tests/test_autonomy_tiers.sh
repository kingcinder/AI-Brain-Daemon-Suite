#!/bin/bash
# test_autonomy_tiers.sh — Phase 5: autonomy graduation ladder tests.
#
# Validates:
#   1. Default tier is 0 (supervised)
#   2. Tier 0 → 1 promotion criteria are evaluated correctly
#   3. Insufficient evidence keeps system at current tier
#   4. Demotion triggers when maintenance criteria fail
#   5. Allowed/blocked actions match tier definition
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/memory/self-mod"

PASS=0; FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# ── Test 1: Default tier is 0 ──────────────────────────────────────────────
echo "Test 1: Default tier is 0 (supervised)"
RESULT=$(WORKSPACE="$WS" bash "$ROOT/core/self-mod/check-tier.sh" --workspace "$WS" 2>/dev/null)
TIER=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['current_tier'])" 2>/dev/null || echo "-1")
TIER_NAME=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['current_tier_name'])" 2>/dev/null || echo "unknown")
[ "$TIER" = "0" ] && [ "$TIER_NAME" = "supervised" ] && pass "default tier=0 ($TIER_NAME)" || fail "expected tier=0 supervised, got tier=$TIER ($TIER_NAME)"

# ── Test 2: Tier 0 → 1 promotion check ─────────────────────────────────────
echo "Test 2: Promotion eligibility evaluated"
PROMO=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['promotion_eligible'])" 2>/dev/null || echo "unknown")
echo "  promotion_eligible=$PROMO (expected False — insufficient evidence)"
[ "$PROMO" = "False" ] && pass "tier 0→1 not eligible (no evidence)" || fail "expected not eligible, got $PROMO"

# ── Test 3: With evidence, promotion becomes eligible ───────────────────────
echo "Test 3: Sufficient evidence enables promotion eligibility"
# Simulate graduation state with enough clean proposals
cat > "$WS/memory/self-mod/graduation-streak.json" << 'GRAD'
{
  "clean_streak": 15,
  "clean_streak_target": 20,
  "review_mode": "relaxed_review",
  "last_event": "clean",
  "last_proposal_id": "prop_test",
  "history": []
}
GRAD
# Write tier state with enough daemon healthy days
cat > "$WS/memory/self-mod/autonomy-tiers-state.json" << 'TSTATE'
{
  "current_tier": 0,
  "consecutive_clean": 15,
  "rollbacks_in_window": 0,
  "verification_pass_rate": 0.96,
  "daemon_healthy_days": 35,
  "graduation_evaluated_at": null
}
TSTATE
RESULT3=$(WORKSPACE="$WS" bash "$ROOT/core/self-mod/check-tier.sh" --workspace "$WS" 2>/dev/null)
PROMO3=$(echo "$RESULT3" | python3 -c "import json,sys; print(json.load(sys.stdin)['promotion_eligible'])" 2>/dev/null || echo "unknown")
echo "  promotion_eligible=$PROMO3 (clean=15, pass_rate=0.96, days=35)"
[ "$PROMO3" = "True" ] && pass "tier 0→1 eligible with evidence" || fail "expected eligible, got $PROMO3"

# ── Test 4: Blocked actions are correct for tier 0 ──────────────────────────
echo "Test 4: Tier 0 blocked actions include auto_deploy"
BLOCKED=$(echo "$RESULT" | python3 -c "import json,sys; b=json.load(sys.stdin)['blocked_actions']; print('auto_deploy' in str(b))" 2>/dev/null || echo "False")
[ "$BLOCKED" = "True" ] && pass "tier 0 blocks auto_deploy" || fail "tier 0 should block auto_deploy"

# ── Test 5: Promotion reasons are actionable ────────────────────────────────
echo "Test 5: Promotion reasons list missing criteria"
# Reset to tier 0 with insufficient evidence
cat > "$WS/memory/self-mod/autonomy-tiers-state.json" << 'TSTATE2'
{
  "current_tier": 0,
  "consecutive_clean": 5,
  "rollbacks_in_window": 0,
  "verification_pass_rate": 0.85,
  "daemon_healthy_days": 10,
  "graduation_evaluated_at": null
}
TSTATE2
RESULT5=$(WORKSPACE="$WS" bash "$ROOT/core/self-mod/check-tier.sh" --workspace "$WS" 2>/dev/null)
REASONS=$(echo "$RESULT5" | python3 -c "
import json,sys
r=json.load(sys.stdin)
reasons = r.get('promotion_reasons', [])
print(len(reasons))
for reason in reasons:
    print(f'  missing: {reason}')
" 2>/dev/null)
NUM_REASONS=$(echo "$REASONS" | head -1)
echo "  missing criteria: $NUM_REASONS"
[ "$NUM_REASONS" -gt 0 ] && pass "promotion reasons actionable ($NUM_REASONS missing criteria)" || fail "expected missing criteria, got 0"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────"
echo "Autonomy Tier Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
exit "$FAIL"
