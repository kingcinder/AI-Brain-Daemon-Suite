#!/bin/bash
# test_m5_proposal_linkage.sh — ROADMAP M5: outcome-driven proposal generation.
#
# Proves the signal → proposal → target linkage through the REAL generator:
#   * A fixture with a known verification failure must steer
#     generate-proposals-llm.sh --emit-target to that failing module's script
#     (the suite aims its self-modification at measured weaknesses).
#   * With no failure signals, the generator falls back to the static
#     preference list (steered_by=preference).
#   * The emitted target must pass check-target (mutable module, real file).
#
# Uses an isolated temp WORKSPACE for the health signals; the suite tree
# itself is read-only (SUITE_ROOT = repo root). No LLM call happens:
# --emit-target resolves the target and exits before any provider is hit.
#
# Run: bash tests/test_m5_proposal_linkage.sh
# Requires: bash, jq, python3

set -euo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/core/self-mod/generate-proposals-llm.sh"
WS=$(mktemp -d)
WS2=$(mktemp -d)
trap 'rm -rf "$WS" "$WS2"' EXIT
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

[ -x "$GEN" ] || { echo "FAIL: generate-proposals-llm.sh not executable"; exit 1; }
mkdir -p "$WS/memory/self-mod/proposals"

# ── Seed a verification failure for a real mutable module ────────────────
# acc-error-memory is mutable (capability-manifest.json immutable=false) and
# has scripts/ — a realistic M5 target. The failure list format matches what
# verification-memory's sweep writes to verification-report.jsonl.
cat > "$WS/memory/verification-report.jsonl" << 'EOF'
{"ts":"2026-08-08T07:56:00Z","filter":"all","totals":{"tests":21,"passed":19,"failed":2},"failures":["acc-error-memory:tests/test_x.sh (exit 1)","vta-memory:tests/test_y.sh (missing)"]}
EOF

echo "Test 1: a known verification failure steers the proposal target"
OUT=$(WORKSPACE="$WS" bash "$GEN" --suite-root "$ROOT" --emit-target 2>/dev/null || true)
if echo "$OUT" | jq -e '.module == "acc-error-memory" and (.target | startswith("skills/acc-error-memory/"))' >/dev/null 2>&1; then
  pass "target module steered to the failing module (acc-error-memory)"
else
  fail "expected acc-error-memory target, got: $OUT"
fi
if echo "$OUT" | jq -e '.steered_by == "health"' >/dev/null 2>&1; then
  pass "steered_by=health (outcome-driven, not convenience)"
else
  fail "steered_by not health: $OUT"
fi

# ── The emitted target must be a real file under the suite ───────────────
echo "Test 2: emitted target is a real, mutable, check-target-valid file"
TARGET=$(echo "$OUT" | jq -r '.target' 2>/dev/null || true)
if [ -n "$TARGET" ] && [ -f "$ROOT/$TARGET" ]; then
  pass "emitted target exists in the suite: $TARGET"
else
  fail "emitted target not a real file: $TARGET"
fi
# check-target is already run inside the generator before emit; re-verify the
# module is mutable via its manifest (the generator only lists immutable=false).
if jq -e '.immutable == false' "$ROOT/skills/acc-error-memory/capability-manifest.json" >/dev/null 2>&1; then
  pass "target module is mutable (immutable=false)"
else
  fail "acc-error-memory manifest not mutable"
fi

# ── Test 3: no health signals → static preference fallback ───────────────
echo "Test 3: no failures → static preference list (steered_by=preference)"
OUT2=$(WORKSPACE="$WS2" bash "$GEN" --suite-root "$ROOT" --emit-target 2>/dev/null || true)
if echo "$OUT2" | jq -e '.steered_by == "preference" and .module == "cerebellum-memory"' >/dev/null 2>&1; then
  pass "empty workspace falls back to first static preference (cerebellum-memory)"
else
  fail "preference fallback wrong: $OUT2"
fi

# ── Test 4: --module override still wins over health signals ─────────────
echo "Test 4: explicit --module override beats health steering"
OUT3=$(WORKSPACE="$WS" bash "$GEN" --suite-root "$ROOT" --module heartbeat-memory --emit-target 2>/dev/null || true)
if echo "$OUT3" | jq -e '.module == "heartbeat-memory" and (.target | startswith("skills/heartbeat-memory/"))' >/dev/null 2>&1; then
  pass "explicit --module override respected (heartbeat-memory)"
else
  fail "module override ignored: $OUT3"
fi

echo ""
echo "─────────────────────────────────────────"
echo "M5 Proposal Linkage Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
