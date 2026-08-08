#!/bin/bash
# test_cycle_defer_alert.sh — The weekly self-mod cycle must ALERT on deferral.
#
# When proposal-cycle-tick.sh runs under a steward_mode + full_review contract,
# the pipeline defers (--defer-gate) instead of churning — and the tick must
# make that visible, not silent:
#   1. A brain-events.jsonl signal ({type:"self-mod", event:"cycle_deferred"}).
#   2. A daemon-status marker (memory/self-mod/last-deferral.json) that
#      deep-brain-kernel.py --status and the dashboard /__daemon + status bar
#      read — so a steward who expected the weekly cycle to run notices it
#      waited for the human.
# Also: an auto_mode contract runs (not defers) and CLEARS the marker.
#
# Run: bash tests/test_cycle_defer_alert.sh
# Requires: bash, jq, python3 (the suite's standard set)

set -euo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── Setup: a steward_mode + full_review contract workspace ───────────────
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/memory/self-mod/pipeline-runs"
cat > "$WS/memory/self-mod/autonomy-state.json" << 'EOF'
{"mode":"steward_mode","auto":false,"computed_at":"2026-08-08T09:00:00Z","evidence":{}}
EOF

echo "Test 1: steward+full_review → tick defers and alerts"
if WORKSPACE="$WS" bash "$ROOT/skills/self-mod-runner/scripts/proposal-cycle-tick.sh" \
    >/tmp/cda_out.$$ 2>/tmp/cda_err.$$; then
  pass "tick exits 0 on deferral (defer is a successful no-op, not a failure)"
else
  cat /tmp/cda_err.$$ >&2
  fail "tick exits 0 on deferral (rc=$?)"
fi
rm -f /tmp/cda_out.$$ /tmp/cda_err.$$

# 1) latest.json genuinely deferred
if jq -e '.deferred == true' "$WS/memory/self-mod/pipeline-runs/latest.json" >/dev/null 2>&1; then
  pass "pipeline run marked deferred:true in latest.json"
else
  fail "latest.json not deferred: $(cat "$WS/memory/self-mod/pipeline-runs/latest.json" 2>/dev/null)"
fi

# 2) brain-events.jsonl signal
if [ -f "$WS/memory/brain-events.jsonl" ] && \
   jq -se 'any(.[]; .type == "self-mod" and .event == "cycle_deferred" and .autonomy_mode == "steward_mode")' \
     "$WS/memory/brain-events.jsonl" >/dev/null 2>&1; then
  pass "brain-events.jsonl carries the self-mod cycle_deferred signal"
else
  fail "brain-events.jsonl missing cycle_deferred: $(cat "$WS/memory/brain-events.jsonl" 2>/dev/null)"
fi

# 3) daemon-status marker
if [ -f "$WS/memory/self-mod/last-deferral.json" ] && \
   jq -e '.deferred == true and .autonomy_mode == "steward_mode" and .review_mode == "full_review"' \
     "$WS/memory/self-mod/last-deferral.json" >/dev/null 2>&1; then
  pass "last-deferral.json marker written (deferred, steward+full_review)"
else
  fail "last-deferral.json malformed: $(cat "$WS/memory/self-mod/last-deferral.json" 2>/dev/null)"
fi

# 4) kernel --status surfaces it
STATUS_OUT=$(WORKSPACE="$WS" python3 "$ROOT/deep-brain-kernel.py" --status 2>&1 || true)
if echo "$STATUS_OUT" | grep -q 'DEFERRED'; then
  pass "--status prints the DEFERRED line (steward sees it in the terminal)"
else
  fail "--status missing DEFERRED line: $STATUS_OUT"
fi

# ── Test 2: auto_mode contract → runs, and the marker is cleared ─────────
echo "Test 2: auto_mode → cycle runs and clears a stale deferral marker"
WS2=$(mktemp -d)
mkdir -p "$WS2/memory/self-mod/pipeline-runs"
# The tick refreshes the contract via deep-brain-kernel.py --autonomy BEFORE
# the pipeline runs — so auto_mode must be *earned by evidence*, not just
# declared: seed a graduation streak at/above target (plus zero unhealthy jobs
# and zero rollbacks, which hold by default in a fresh workspace) so the
# refresh recomputes auto_mode and the pipeline genuinely runs non-deferred.
cat > "$WS2/memory/self-mod/graduation-streak.json" << 'EOF'
{"clean_streak": 22, "clean_streak_target": 20, "review_mode": "relaxed_review"}
EOF
cat > "$WS2/memory/self-mod/autonomy-state.json" << 'EOF'
{"mode":"auto_mode","auto":true,"computed_at":"2026-08-08T09:00:00Z","evidence":{}}
EOF
# Seed a stale marker (as if a prior deferral was never cleared).
echo '{"deferred":true,"at":"2026-08-07T09:00:00Z","autonomy_mode":"steward_mode","review_mode":"full_review","reason":"steward_full_review_deferred"}' \
  > "$WS2/memory/self-mod/last-deferral.json"

if WORKSPACE="$WS2" bash "$ROOT/skills/self-mod-runner/scripts/proposal-cycle-tick.sh" \
    >/tmp/cda2_out.$$ 2>/tmp/cda2_err.$$; then
  pass "tick exits 0 under auto_mode (pipeline runs, LLM gen degrades gracefully)"
else
  cat /tmp/cda2_err.$$ >&2
  fail "tick exits 0 under auto_mode (rc=$?)"
fi
rm -f /tmp/cda2_out.$$ /tmp/cda2_err.$$

if [ ! -f "$WS2/memory/self-mod/last-deferral.json" ]; then
  pass "stale deferral marker cleared after a non-deferred run"
else
  fail "stale marker not cleared: $(cat "$WS2/memory/self-mod/last-deferral.json" 2>/dev/null)"
fi
# The auto_mode run must NOT have minted a fresh deferral signal.
if [ -f "$WS2/memory/brain-events.jsonl" ] && jq -se 'any(.[]; .event == "cycle_deferred")' "$WS2/memory/brain-events.jsonl" >/dev/null 2>&1; then
  fail "auto_mode run wrongly wrote a cycle_deferred signal"
else
  pass "auto_mode run writes no deferral signal (cycle actually ran)"
fi
rm -rf "$WS2"

echo ""
echo "─────────────────────────────────────────"
echo "Cycle Deferral Alert Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
