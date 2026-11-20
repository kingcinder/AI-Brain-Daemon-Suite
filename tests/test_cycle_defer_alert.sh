#!/bin/bash
# test_cycle_defer_alert.sh — M9 contract: the weekly self-mod cycle NEVER defers.
#
# Before M9, proposal-cycle-tick.sh under a steward_mode + full_review
# contract deferred (--defer-gate) and the tick had to alert on it. M9
# (Dither's order, 2026-11-13) moved the approval gate to Juno: the cycle
# always runs, no proposal waits for a human, and no deferral artifacts
# are produced. This test now proves the negative space:
#   1. latest.json is NOT deferred under steward_mode + full_review.
#   2. No cycle_deferred signal is written to brain-events.jsonl.
#   3. No last-deferral.json marker is written — and a stale pre-M9 marker
#      is CLEARED by the run.
#   4. deep-brain-kernel.py --status shows no DEFERRED line.
# Also: an auto_mode contract runs and clears the marker (unchanged).
#
# Run: bash tests/test_cycle_defer_alert.sh
# Requires: bash, jq, python3 (the suite's standard set)

set -euo pipefail
# Juno-direct: proposal generation asks Juno through the helm queue and
# degrades gracefully when no drainer answers. Bound that wait so the cycle
# tests stay fast — the degrade path is what is under test, not the wait.
export JUNO_PROPOSAL_TIMEOUT="${JUNO_PROPOSAL_TIMEOUT:-25}"
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
# Seed a stale pre-M9 marker — the M9 run must clear it, not refresh it.
echo '{"deferred":true,"at":"2026-08-07T09:00:00Z","autonomy_mode":"steward_mode","review_mode":"full_review","reason":"steward_full_review_deferred"}' \
  > "$WS/memory/self-mod/last-deferral.json"

echo "Test 1: steward+full_review → tick RUNS under M9 (no deferral)"
if WORKSPACE="$WS" bash "$ROOT/skills/self-mod-runner/scripts/proposal-cycle-tick.sh" \
    >/tmp/cda_out.$$ 2>/tmp/cda_err.$$; then
  pass "tick exits 0 under steward+full_review (cycle ran)"
else
  cat /tmp/cda_err.$$ >&2
  fail "tick exits 0 under steward+full_review (rc=$?)"
fi
rm -f /tmp/cda_out.$$ /tmp/cda_err.$$

# 1) latest.json is a normal run, not deferred
if jq -e '.deferred != true' "$WS/memory/self-mod/pipeline-runs/latest.json" >/dev/null 2>&1; then
  pass "pipeline run NOT deferred in latest.json"
else
  fail "latest.json deferred under M9: $(cat "$WS/memory/self-mod/pipeline-runs/latest.json" 2>/dev/null)"
fi

# 2) no brain-events.jsonl deferral signal
if [ -f "$WS/memory/brain-events.jsonl" ] && \
   jq -se 'any(.[]; .type == "self-mod" and .event == "cycle_deferred")' \
     "$WS/memory/brain-events.jsonl" >/dev/null 2>&1; then
  fail "brain-events.jsonl carries a cycle_deferred signal under M9: $(cat "$WS/memory/brain-events.jsonl" 2>/dev/null)"
else
  pass "brain-events.jsonl carries no cycle_deferred signal"
fi

# 3) stale marker cleared, none written
if [ ! -f "$WS/memory/self-mod/last-deferral.json" ]; then
  pass "stale last-deferral.json cleared; no new marker written"
else
  fail "last-deferral.json still present after M9 run: $(cat "$WS/memory/self-mod/last-deferral.json" 2>/dev/null)"
fi

# 4) kernel --status surfaces no DEFERRED line
STATUS_OUT=$(WORKSPACE="$WS" python3 "$ROOT/deep-brain-kernel.py" --status 2>&1 || true)
if echo "$STATUS_OUT" | grep -q 'DEFERRED'; then
  fail "--status prints a DEFERRED line under M9: $STATUS_OUT"
else
  pass "--status prints no DEFERRED line"
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
  pass "tick exits 0 under auto_mode (pipeline runs, Juno gen degrades gracefully)"
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
echo "Cycle Deferral (M9) Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
