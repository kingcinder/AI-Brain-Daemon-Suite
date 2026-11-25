#!/bin/bash
# run_phase1_harness.sh — Automated regression suite for Phase 1a/1b core.
# Covers: pid-lock, schema, provenance, executive-load, semaphore, snapshot,
#         sandbox, and existing decide.sh harness.
#
# Usage: bash tests/run_phase1_harness.sh
# Exit non-zero if any suite fails.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
FAILURES=0
PASSES=0

pass() { echo "  PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

section() { echo ""; echo "=== $1 ==="; }

# Isolated workspace for all tests
export WORKSPACE
WORKSPACE=$(mktemp -d)
mkdir -p "$WORKSPACE/memory"
trap 'rm -rf "$WORKSPACE"' EXIT

chmod +x "$CORE"/locks/*.sh "$CORE"/schema/*.sh "$CORE"/provenance/*.sh \
  "$CORE"/executive-load/*.sh "$CORE"/concurrency/*.sh "$CORE"/snapshot/*.sh \
  "$CORE"/sandbox/*.sh 2>/dev/null || true

# ── 1. Schema registry ──────────────────────────────────────────────────────
section "schema-registry"
if bash "$CORE/schema/validate-schema.sh" --check-registry; then
  pass "registry structure"
else
  fail "registry structure"
fi

# ── 2. PID lock acquire / release / crash reclaim ───────────────────────────
section "pid-lock"
LOCKDIR="$WORKSPACE/locks/pidtest"
# shellcheck source=/dev/null
source "$CORE/locks/pid-lock.sh"
if pid_lock_acquire "$LOCKDIR" 90; then
  pass "acquire"
else
  fail "acquire"
fi
pid_lock_heartbeat "$LOCKDIR"
if [ -f "$LOCKDIR/heartbeat" ]; then
  pass "heartbeat"
else
  fail "heartbeat"
fi
pid_lock_release "$LOCKDIR"
if [ ! -f "$LOCKDIR/pid" ]; then
  pass "release clears pid"
else
  fail "release clears pid"
fi

# Stale reclaim: write dead pid + old heartbeat, then acquire
mkdir -p "$LOCKDIR"
echo "1" > "$LOCKDIR/pid"
echo "0" > "$LOCKDIR/starttime"
echo "0" > "$LOCKDIR/heartbeat"   # very stale
# Need a fake flock holder? Without flock held, acquire should succeed immediately
if pid_lock_acquire "$LOCKDIR" 5; then
  pass "stale reclaim acquire"
  pid_lock_release "$LOCKDIR"
else
  fail "stale reclaim acquire"
fi

# ── 3. Provenance ───────────────────────────────────────────────────────────
section "provenance"
ENTRY=$(bash "$CORE/provenance/log-provenance.sh" append \
  --proposal-id "test-prop-1" \
  --content "hello-world-patch" \
  --parent-hash "abc123" \
  --proposer "harness" \
  --sandbox-score 0.9 \
  --utility-score 0.5 \
  --rollback-status none)
if echo "$ENTRY" | jq -e '.proposal_id=="test-prop-1" and .content_hash and .timestamp' >/dev/null; then
  pass "append entry"
else
  fail "append entry"
fi
H=$(bash "$CORE/provenance/log-provenance.sh" hash "hello-world-patch")
if [ "${#H}" -eq 64 ]; then
  pass "sha256 length"
else
  fail "sha256 length"
fi
SHOW=$(bash "$CORE/provenance/log-provenance.sh" show --limit 5)
if echo "$SHOW" | jq -e 'type=="array" and length>=1' >/dev/null; then
  pass "show log"
else
  fail "show log"
fi

# ── 4. Executive load formula ───────────────────────────────────────────────
section "executive-load"
# E = (2*0.06)+(1*0.12)+(5/25) = 0.12+0.12+0.2 = 0.44
EJSON=$(bash "$CORE/executive-load/calc-executive-load.sh" --goals 2 --queue 1 --i-sec 5 --tick 3)
E=$(echo "$EJSON" | jq -r .E)
BAND=$(echo "$EJSON" | jq -r .band)
if python3 -c "import sys; sys.exit(0 if abs(float('$E')-0.44)<1e-6 else 1)"; then
  pass "E=0.44 for G=2,Q=1,I=5"
else
  fail "E=0.44 for G=2,Q=1,I=5 (got $E)"
fi
if [ "$BAND" = "desired" ]; then
  pass "band desired"
else
  fail "band desired (got $BAND)"
fi
# Clip at 1.0: G=20,Q=10,I=100 → huge
ECLIP=$(bash "$CORE/executive-load/calc-executive-load.sh" --goals 20 --queue 10 --i-sec 100 | jq -r .E)
CLIPPED=$(bash "$CORE/executive-load/calc-executive-load.sh" --goals 20 --queue 10 --i-sec 100 | jq -r .clipped)
if [ "$ECLIP" = "1.0" ] || [ "$ECLIP" = "1.000000" ]; then
  pass "E clips at 1.0"
else
  # jq may print 1
  if python3 -c "import sys; sys.exit(0 if float('$ECLIP')==1.0 else 1)"; then
    pass "E clips at 1.0"
  else
    fail "E clips at 1.0 (got $ECLIP)"
  fi
fi
if [ "$CLIPPED" = "true" ]; then
  pass "clipped flag true"
else
  fail "clipped flag true"
fi

# ── 5. Concurrency semaphore + KV cap ───────────────────────────────────────
section "concurrency-semaphore"
# shellcheck source=/dev/null
source "$CORE/concurrency/semaphore.sh"
SEM="$WORKSPACE/memory/locks/inference-semaphore"
# Hold the slot in a background subshell (same-process flock re-open would drop it)
(
  source "$CORE/concurrency/semaphore.sh"
  semaphore_acquire_inference "$SEM" || exit 1
  # Keep hold long enough for the main test to try a second acquire
  sleep 5
  semaphore_release_inference "$SEM"
) &
HOLDER_PID=$!
sleep 0.3
if ! semaphore_acquire_inference "$SEM"; then
  pass "second acquire blocked while other process holds slot"
else
  fail "second acquire blocked while other process holds slot"
  semaphore_release_inference "$SEM"
fi
wait "$HOLDER_PID" 2>/dev/null || true
if semaphore_acquire_inference "$SEM"; then
  pass "acquire inference slot after release"
  semaphore_release_inference "$SEM"
else
  fail "acquire inference slot after release"
fi
if semaphore_check_kv_cap 2048; then
  pass "KV cap allows 2048"
else
  fail "KV cap allows 2048"
fi
if ! semaphore_check_kv_cap 2049; then
  pass "KV cap rejects 2049"
else
  fail "KV cap rejects 2049"
fi

# ── 6. Snapshot + divergence ────────────────────────────────────────────────
section "snapshot-divergence"
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{"version":"1.0","lastUpdated":"","executiveLoad":0.3,
 "goals":[{"description":"g1","priority":0.8,"status":"active"}],
 "inhibitions":[{"pattern":"x","reason":"y","strength":0.5}],
 "decisionLog":[]}
EOF
echo '{"E":0.4,"G":1,"Q":0,"I_sec":0,"tick":1,"timestamp":"t"}' > "$WORKSPACE/memory/executive-load.json"

SNAP=$(bash "$CORE/snapshot/snapshot.sh" create --label harness)
SID=$(echo "$SNAP" | jq -r .snapshot_id)
if [ -n "$SID" ] && [ "$SID" != "null" ]; then
  pass "create snapshot"
else
  fail "create snapshot"
fi

DIV=$(bash "$CORE/snapshot/snapshot.sh" divergence-check --baseline "$SID" --current-eload 0.4)
if echo "$DIV" | jq -e '.retest_required==false' >/dev/null; then
  pass "no divergence at same state"
else
  fail "no divergence at same state: $DIV"
fi

# Change goals → retest
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{"version":"1.0","lastUpdated":"","executiveLoad":0.3,
 "goals":[{"description":"g1","priority":0.8,"status":"active"},
          {"description":"g2","priority":0.5,"status":"active"}],
 "inhibitions":[{"pattern":"x","reason":"y","strength":0.5}],
 "decisionLog":[]}
EOF
DIV2=$(bash "$CORE/snapshot/snapshot.sh" divergence-check --baseline "$SID" --current-eload 0.4)
if echo "$DIV2" | jq -e '.retest_required==true and .goals_changed==true' >/dev/null; then
  pass "goals change triggers retest"
else
  fail "goals change triggers retest: $DIV2"
fi

# Executive load delta > 0.12
DIV3=$(bash "$CORE/snapshot/snapshot.sh" divergence-check --baseline "$SID" --current-eload 0.6)
if echo "$DIV3" | jq -e '.executive_load_divergent==true' >/dev/null; then
  pass "eload delta > 0.12 triggers retest"
else
  fail "eload delta > 0.12 triggers retest: $DIV3"
fi

# ── 7. Sandbox harness ──────────────────────────────────────────────────────
section "sandbox"
SB=$(bash "$CORE/sandbox/sandbox-run.sh" --cmd 'echo hello-sandbox; exit 0' --label harness --timeout 30)
if echo "$SB" | grep -q 'SANDBOX_RESULT:'; then
  if echo "$SB" | grep 'SANDBOX_RESULT:' | sed 's/SANDBOX_RESULT: //' | jq -e '.success==true' >/dev/null; then
    pass "sandbox success path"
  else
    fail "sandbox success path: $SB"
  fi
else
  fail "sandbox success path (no result line)"
fi
set +e
SB2=$(bash "$CORE/sandbox/sandbox-run.sh" --cmd 'exit 7' --label harness-fail --timeout 30)
SB2_RC=$?
set -e
if [ "$SB2_RC" -eq 7 ]; then
  pass "sandbox propagates exit code"
else
  fail "sandbox propagates exit code (rc=$SB2_RC)"
fi

# ── 8. Schema validate sample executive-load ────────────────────────────────
section "schema-validate-sample"
SAMPLE="$WORKSPACE/memory/executive-load-sample.json"
bash "$CORE/executive-load/calc-executive-load.sh" --goals 1 --queue 0 --i-sec 0 --write "$SAMPLE" >/dev/null
# Add schema fields already present; validate document type
if bash "$CORE/schema/validate-schema.sh" executive-load-sample "$SAMPLE"; then
  pass "executive-load-sample schema"
else
  fail "executive-load-sample schema"
fi

# ── 9. decide.sh harness (existing) ─────────────────────────────────────────
section "pfc-decide-harness"
if bash "$ROOT/tests/pfc_decide_harness.sh" "$ROOT/skills/prefrontal-cortex-memory"; then
  pass "decide.sh closed-loop harness"
else
  fail "decide.sh closed-loop harness"
fi

# ── 10. RWLock smoke ────────────────────────────────────────────────────────
section "rwlock"
# shellcheck source=/dev/null
source "$CORE/locks/rwlock.sh"
RW="$WORKSPACE/locks/rwtest"
if rwlock_try_read_acquire "$RW"; then
  pass "try-read acquire"
  rwlock_read_release "$RW"
else
  fail "try-read acquire"
fi
if rwlock_write_acquire "$RW" 30 5; then
  pass "write acquire"
  # Non-blocking read should fail while write held (same process still holds write fd)
  # Note: same shell holds write fd 220 — try-read uses 210; write lock exclusive blocks shared
  if ! rwlock_try_read_acquire "$RW"; then
    pass "try-read blocked during write"
  else
    # return 2 means blocked
    fail "try-read blocked during write (unexpectedly acquired)"
    rwlock_read_release "$RW"
  fi
  rwlock_write_release "$RW"
else
  fail "write acquire"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Phase 1 harness: $PASSES passed, $FAILURES failed"
echo "========================================"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
