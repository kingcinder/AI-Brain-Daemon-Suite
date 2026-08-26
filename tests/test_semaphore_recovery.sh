#!/bin/bash
# test_semaphore_recovery.sh — Crash-drift regression for the inference semaphore.
#
# The bug it guards: semaphore_acquire_inference() increments contexts.count
# and only semaphore_release_inference() decrements it. If a holder dies
# without running release (kill -9, OOM, power loss), the count stays
# inflated forever — eventually blocking ALL inference (contexts > max).
# The fix reconciles a stale holder at acquire time: if the recorded
# holder.pid is no longer alive, the previous holder crashed, so the count
# is reset before this acquire's increment.
#
# Run: bash tests/test_semaphore_recovery.sh
# Requires: jq (already in the Suite's dependency set)

set -euo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS="$(mktemp -d)"
SEM="$WS/locks/inference-semaphore"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

cleanup() {
    rm -rf "$WS"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$ROOT/core/concurrency/semaphore.sh"

# ── Test 1: normal acquire → release round-trips the count ──────────────
echo "Test 1: acquire/release round-trip"
if semaphore_acquire_inference "$SEM"; then
    pass "acquire succeeds on a fresh semaphore"
else
    fail "acquire failed on a fresh semaphore"
fi
C1=$(cat "$SEM/contexts.count")
if [ "$C1" = "2" ]; then
    pass "contexts.count=2 after first acquire (primary + this background)"
else
    fail "contexts.count=$C1 expected 2"
fi
semaphore_release_inference "$SEM"
C2=$(cat "$SEM/contexts.count")
if [ "$C2" = "1" ]; then
    pass "contexts.count=1 after release"
else
    fail "contexts.count=$C2 expected 1 after release"
fi

# ── Test 2: simulate a crashed holder → next acquire must reclaim ────────
echo "Test 2: stale-holder reconciliation (crash drift)"
# Simulate a holder that acquired (count=2), then died without release:
# holder.pid points at a dead pid, contexts.count stays inflated at 2.
echo "999999" > "$SEM/holder.pid"
date +%s > "$SEM/holder.since"
echo "inference" > "$SEM/holder.kind"
echo "2" > "$SEM/contexts.count"

# The stale holder pid is not alive, so the NEXT acquire must reset the
# count before incrementing — otherwise contexts would go 2→3 > max and
# every future acquire would fail forever.
if semaphore_acquire_inference "$SEM"; then
    pass "acquire succeeds despite an inflated count from a crashed holder"
    C3=$(cat "$SEM/contexts.count")
    if [ "$C3" = "2" ]; then
        pass "contexts.count reconciled to 2 (reset 0 → +1 → 2), not 3"
    else
        fail "contexts.count=$C3 expected 2 after reconciliation"
    fi
else
    fail "acquire blocked — stale-holder reconciliation did not reset the drift"
fi
semaphore_release_inference "$SEM"

# ── Test 3: a LIVE holder must NOT be treated as stale ───────────────────
echo "Test 3: live holder is not reconciled away"
# Record the current (live) shell as the holder with an inflated count.
echo "$$" > "$SEM/holder.pid"
echo "2" > "$SEM/contexts.count"
# Because $$ is alive, the reconciliation must NOT reset the count — the
# acquire would legitimately exceed max and be refused.
if semaphore_acquire_inference "$SEM"; then
    fail "acquire succeeded with a live holder at the cap (should refuse)"
    semaphore_release_inference "$SEM"
else
    pass "acquire correctly refused while a live holder is at the cap"
fi

echo ""
echo "Semaphore recovery tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
