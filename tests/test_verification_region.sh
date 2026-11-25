#!/bin/bash
# test_verification_region.sh — Self-test for the verification-memory region.
#
# Verifies the manifest-driven contract without touching the real suite:
#  1. run-declared-tests.sh discovers tests from fake capability manifests
#  2. a failing declared test makes the sweep exit 1 and publish test_failure
#  3. --module targets one module's declared tests
#  4. --list prints the declared test table
#  5. run-module-tests.sh enforces a cooldown between runs of the same module
#  6. state + report ledger + VERIFICATION_STATE.md are written
#
# Run: bash tests/test_verification_region.sh
# Requires: jq

set -euo pipefail

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="$ROOT/skills/verification-memory/scripts"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── Build a fake suite: two skills, one passing test + one failing test ──
SUITE="$TMP/suite"
WS="$TMP/ws"
mkdir -p "$SUITE/skills/fake-a" "$SUITE/skills/fake-b" "$SUITE/tests" \
         "$SUITE/core/executive" "$WS/memory"

cat > "$SUITE/skills/fake-a/capability-manifest.json" << 'EOF'
{
  "schema": 1,
  "module": "fake-a",
  "version": "1.0.0",
  "capabilities": ["fake"],
  "inputs": [],
  "outputs": [],
  "side_effects": ["none"],
  "dependencies": [],
  "tests": [{"path": "tests/test_fake_a.sh", "kind": "unit"}],
  "immutable": false
}
EOF
cat > "$SUITE/skills/fake-b/capability-manifest.json" << 'EOF'
{
  "schema": 1,
  "module": "fake-b",
  "version": "1.0.0",
  "capabilities": ["fake"],
  "inputs": [],
  "outputs": [],
  "side_effects": ["none"],
  "dependencies": [],
  "tests": [{"path": "tests/test_fake_b.sh", "kind": "regression"}],
  "immutable": false
}
EOF
cat > "$SUITE/core/executive/capability-manifest.json" << 'EOF'
{
  "schema": 1,
  "module": "executive-function",
  "version": "1.0.0",
  "capabilities": ["fake"],
  "inputs": [],
  "outputs": [],
  "side_effects": ["none"],
  "dependencies": [],
  "tests": [{"path": "tests/test_exec_fake.sh", "kind": "regression"}],
  "immutable": false
}
EOF
# Executive declares a test path that does NOT exist → must count as a failure
printf '#!/bin/bash\nexit 0\n' > "$SUITE/tests/test_fake_a.sh"
printf '#!/bin/bash\nexit 1\n' > "$SUITE/tests/test_fake_b.sh"
chmod +x "$SUITE/tests/"*.sh

# Symlink the real publish.sh so signal publishing is exercised for real
mkdir -p "$SUITE/core/signaling"
ln -s "$ROOT/core/signaling/publish.sh" "$SUITE/core/signaling/publish.sh"

export SUITE_ROOT="$SUITE"
export WORKSPACE="$WS"

# ── Test 1: --list prints the declared test table ────────────────────────
echo "Test 1: --list discovers declared tests from manifests"
LIST=$("$VM/run-declared-tests.sh" --list)
if echo "$LIST" | grep -q "fake-a.*test_fake_a.sh" && \
   echo "$LIST" | grep -q "fake-b.*test_fake_b.sh" && \
   echo "$LIST" | grep -q "executive-function.*test_exec_fake.sh"; then
    pass "list shows all three declared tests"
else
    fail "list missing declared tests: $LIST"
fi

# ── Test 2: full sweep — one pass, one fail, one missing → exit 1 ────────
echo "Test 2: full sweep aggregates results and fails on red"
set +e
OUT=$("$VM/run-declared-tests.sh" --quiet 2>&1)
RC=$?
set -e
if [ "$RC" -ne 1 ]; then
    fail "sweep should exit 1 with a failing test (rc=$RC)"
else
    pass "sweep exits 1 when a declared test fails"
fi
if [ -f "$WS/memory/verification-state.json" ]; then
    FAILED=$(jq -r '.totals.failed' "$WS/memory/verification-state.json")
    if [ "$FAILED" -ge 2 ]; then
        pass "state totals count failures ($FAILED: fake-b + missing exec test)"
    else
        fail "state totals.failed=$FAILED, expected >=2"
    fi
else
    fail "verification-state.json not written"
fi

# ── Test 3: test_failure signal published ────────────────────────────────
echo "Test 3: test_failure signal lands on the bus"
if [ -f "$WS/memory/brain-signals.jsonl" ]; then
    if grep -q '"source":"verification-memory"' "$WS/memory/brain-signals.jsonl" && \
       grep -q '"signal":"test_failure"' "$WS/memory/brain-signals.jsonl"; then
        pass "test_failure published with verification-memory source"
    else
        fail "signal log missing test_failure from verification-memory"
    fi
else
    fail "brain-signals.jsonl not written by publish.sh"
fi

# ── Test 4: --module targets one module's declared tests ─────────────────
echo "Test 4: --module runs only that module's tests"
set +e
OUT=$("$VM/run-declared-tests.sh" --module fake-a --quiet 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    pass "--module fake-a passes (its single test exits 0)"
else
    fail "--module fake-a should pass (rc=$RC): $OUT"
fi

# ── Test 5: run-module-tests.sh cooldown skips a second run ──────────────
echo "Test 5: run-module-tests.sh enforces cooldown"
# First call: runs and records a cooldown timestamp for fake-a
"$VM/run-module-tests.sh" --module fake-a --quiet >/dev/null 2>&1
# Second immediate call: must be skipped by the cooldown
OUT=$("$VM/run-module-tests.sh" --module fake-a)
if echo "$OUT" | grep -q "cooldown"; then
    pass "second immediate run within cooldown is skipped"
else
    fail "expected cooldown skip, got: $OUT"
fi

# ── Test 6: --force bypasses cooldown ────────────────────────────────────
echo "Test 6: --force bypasses cooldown"
set +e
OUT=$("$VM/run-module-tests.sh" --module fake-a --force --quiet 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "cooldown"; then
    pass "--force re-runs immediately"
else
    fail "--force should bypass cooldown (rc=$RC): $OUT"
fi

# ── Test 7: report ledger + VERIFICATION_STATE.md written ────────────────
echo "Test 7: report ledger and human-readable state written"
if [ -f "$WS/memory/verification-report.jsonl" ] && [ -s "$WS/memory/verification-report.jsonl" ]; then
    pass "verification-report.jsonl has entries"
else
    fail "verification-report.jsonl missing or empty"
fi
if [ -f "$WS/VERIFICATION_STATE.md" ] && grep -q "Verification State" "$WS/VERIFICATION_STATE.md"; then
    pass "VERIFICATION_STATE.md generated"
else
    fail "VERIFICATION_STATE.md missing"
fi

# ── Test 8: no tests declared → exit 0 with no-op ────────────────────────
echo "Test 8: sweep with no declared tests is a no-op success"
EMPTY="$TMP/empty"
mkdir -p "$EMPTY/skills" "$TMP/ws2/memory"
set +e
SUITE_ROOT="$EMPTY" WORKSPACE="$TMP/ws2" "$VM/run-declared-tests.sh" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    pass "no-manifest suite exits 0"
else
    fail "no-manifest suite should exit 0 (rc=$RC)"
fi

# ── Test 9: report ledger carries per-module breakdown ─────────────────
echo "Test 9: ledger records per-module results"
LEDGER_MODS=$(jq -s '[.[] | select(.filter == "all") | .modules["fake-b"].failed // 0] | add' "$WS/memory/verification-report.jsonl")
if [ -n "$LEDGER_MODS" ] && [ "$LEDGER_MODS" -ge 1 ]; then
    pass "full-sweep entry attributes failures per module (fake-b failed=$LEDGER_MODS)"
else
    fail "ledger missing per-module breakdown (fake-b failed=${LEDGER_MODS:-none})"
fi

# ── Test 10: query-history.sh aggregates a fixture ledger ───────────────
echo "Test 10: query-history.sh per-module pass-rate history"
WQ="$TMP/wsq"
mkdir -p "$WQ/memory"
cat > "$WQ/memory/verification-report.jsonl" << 'EOF'
{"ts":"2026-08-01T00:00:00Z","filter":"all","totals":{"tests":2,"passed":2,"failed":0},"failures":[],"modules":{"fake-a":{"tests":1,"passed":1,"failed":0},"fake-b":{"tests":1,"passed":1,"failed":0}}}
{"ts":"2026-08-02T00:00:00Z","filter":"all","totals":{"tests":2,"passed":1,"failed":1},"failures":["fake-b:tests/test_fake_b.sh (exit 1)"],"modules":{"fake-a":{"tests":1,"passed":1,"failed":0},"fake-b":{"tests":1,"passed":0,"failed":1}}}
{"ts":"2026-08-03T00:00:00Z","filter":"all","totals":{"tests":2,"passed":1,"failed":1},"failures":["fake-b:tests/test_fake_b.sh (exit 1)"],"modules":{"fake-a":{"tests":1,"passed":1,"failed":0},"fake-b":{"tests":1,"passed":0,"failed":1}}}
EOF
Q=$(WORKSPACE="$WQ" "$VM/query-history.sh")
if echo "$Q" | jq -e '.runs_total == 3 and (.modules | length) == 2' >/dev/null; then
    pass "query aggregates 3 runs into 2 modules"
else
    fail "query aggregation: $Q"
fi
if echo "$Q" | jq -e '.modules[] | select(.module=="fake-a") | .pass_rate == 1.0 and .runs == 3' >/dev/null; then
    pass "fake-a pass rate 100% over 3 runs"
else
    fail "fake-a stats: $(echo "$Q" | jq -c '.modules[] | select(.module=="fake-a")')"
fi
if echo "$Q" | jq -e '.modules[] | select(.module=="fake-b") | ((.pass_rate - 0.3333) | fabs) < 0.001 and .runs == 3' >/dev/null; then
    pass "fake-b pass rate 1/3 over 3 runs"
else
    fail "fake-b stats: $(echo "$Q" | jq -c '.modules[] | select(.module=="fake-b")')"
fi
if echo "$Q" | jq -e '.healthiest.module == "fake-a" and .unhealthiest.module == "fake-b"' >/dev/null; then
    pass "healthiest=fake-a, unhealthiest=fake-b"
else
    fail "health ranking: $(echo "$Q" | jq -c '{healthiest, unhealthiest}')"
fi

# ── Test 11: query-history.sh filters (--module/--limit/--text/empty) ──
echo "Test 11: query-history.sh filters"
Q1=$(WORKSPACE="$WQ" "$VM/query-history.sh" --module fake-b)
if echo "$Q1" | jq -e '(.modules | length) == 1 and .modules[0].module == "fake-b"' >/dev/null; then
    pass "--module fake-b returns only fake-b"
else
    fail "--module filter: $Q1"
fi
Q2=$(WORKSPACE="$WQ" "$VM/query-history.sh" --limit 1)
if echo "$Q2" | jq -e '[.modules[].history | length] | all(. == 1)' >/dev/null; then
    pass "--limit 1 truncates history to 1 point per module"
else
    fail "--limit: $Q2"
fi
QT=$(WORKSPACE="$WQ" "$VM/query-history.sh" --text)
if echo "$QT" | grep -q "Healthiest" && echo "$QT" | grep -q "fake-b"; then
    pass "--text renders a trend table with sparkline glyphs"
else
    fail "--text output: $QT"
fi
QE=$(WORKSPACE="$TMP/wsq-empty" "$VM/query-history.sh")
if echo "$QE" | jq -e '.runs_total == 0 and .modules == [] and .healthiest == null' >/dev/null; then
    pass "empty ledger → empty answer (exit 0)"
else
    fail "empty ledger: $QE"
fi

# ── Test 12: dashboard fragment carries long-term health data ──────────
echo "Test 12: 🩺 dashboard fragment includes long-term health"
"$VM/generate-dashboard.sh" >/dev/null 2>&1 || true
if [ -f "$WS/memory/dashboard-fragments/verification.json" ]; then
    if jq -e '(.data.history | type) == "array" and (.data.modules | type) == "array" and (.data.healthiest | type) == "object"' "$WS/memory/dashboard-fragments/verification.json" >/dev/null 2>&1; then
        pass "fragment data carries history + modules + healthiest"
    else
        fail "fragment data missing health fields: $(jq -c '.data | {history: (.data.history // [] | type), modules: (.data.modules // [] | type), healthiest: (.data.healthiest // null | type)}' "$WS/memory/dashboard-fragments/verification.json" 2>/dev/null)"
    fi
else
    fail "verification.json fragment not written"
fi

echo ""
echo "─────────────────────────────────────────"
echo "Verification Region Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
