#!/bin/bash
# run_phase2_harness.sh — Phase 2 executive function + registry checks.
# Covers: isolated reflection (no live writes), goal proposal queue,
#         promote caps / load gate, skill manifest, concurrency KV contract.
#
# Usage: bash tests/run_phase2_harness.sh
# Exit non-zero if any assertion fails.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
FAILURES=0
PASSES=0

pass() { echo "  PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
section() { echo ""; echo "=== $1 ==="; }

export WORKSPACE
WORKSPACE=$(mktemp -d)
mkdir -p "$WORKSPACE/memory"
trap 'rm -rf "$WORKSPACE"' EXIT

chmod +x "$CORE"/executive/*.sh "$ROOT"/skills/executive-function/scripts/*.sh 2>/dev/null || true

# ── Fixture: empty goals + pending queue + elevated E signal ────────────────
section "fixtures"
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "2026-01-01T00:00:00Z",
  "executiveLoad": 0.2,
  "goals": [],
  "inhibitions": [],
  "decisionLog": []
}
EOF
cat > "$WORKSPACE/memory/decision-queue.json" << 'EOF'
{"pending":[{"id":"d1","question":"ship or wait?"},{"id":"d2","question":"refactor?"}]}
EOF
cat > "$WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.2, "band": "underutilized", "G": 0, "Q": 2, "I_sec": 0}
EOF
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{"conflicts":[{"description":"schedule vs deep work","status":"open"}]}
EOF
pass "workspace fixtures written"

# Fingerprint pfc before isolated reflect
PFC_HASH_BEFORE=$(sha256sum "$WORKSPACE/memory/pfc-state.json" | awk '{print $1}')

# ── Isolated reflection: produces file, no pfc mutation ─────────────────────
section "isolated-reflect"
REF_OUT=$(bash "$CORE/executive/isolated-reflect.sh" --workspace "$WORKSPACE" 2>/tmp/iso_err.$$) || {
  cat /tmp/iso_err.$$ >&2
  fail "isolated-reflect exit"
  REF_OUT=""
}
rm -f /tmp/iso_err.$$
if [ -n "$REF_OUT" ] && [ -f "$REF_OUT" ]; then
  pass "reflection file created"
else
  fail "reflection file created"
fi

PFC_HASH_AFTER=$(sha256sum "$WORKSPACE/memory/pfc-state.json" | awk '{print $1}')
if [ "$PFC_HASH_BEFORE" = "$PFC_HASH_AFTER" ]; then
  pass "pfc-state unchanged after isolated reflect"
else
  fail "pfc-state unchanged after isolated reflect"
fi

if [ -f "$REF_OUT" ] && jq -e '.isolation.write_permissions == false and (.goal_proposals|type=="array")' "$REF_OUT" >/dev/null; then
  pass "reflection schema: read-only + proposals array"
else
  fail "reflection schema: read-only + proposals array"
fi

PROP_COUNT=$(jq '.goal_proposals | length' "$REF_OUT" 2>/dev/null || echo 0)
if [ "${PROP_COUNT:-0}" -ge 1 ]; then
  pass "at least one goal proposal from empty goals + queue"
else
  fail "at least one goal proposal from empty goals + queue"
fi

# ── propose-goals without promote ───────────────────────────────────────────
section "propose-goals-queue"
QOUT=$(bash "$CORE/executive/propose-goals.sh" --workspace "$WORKSPACE" --reflection "$REF_OUT" 2>/tmp/pg_err.$$) || {
  cat /tmp/pg_err.$$ >&2
  fail "propose-goals queue exit"
  QOUT="{}"
}
rm -f /tmp/pg_err.$$
if [ -f "$WORKSPACE/memory/executive/goal-proposals.jsonl" ]; then
  pass "goal-proposals.jsonl written"
else
  fail "goal-proposals.jsonl written"
fi
if echo "$QOUT" | jq -e '((.promoted|length)==0) and (.queued>=1)' >/dev/null; then
  pass "queued without promote"
else
  fail "queued without promote ($QOUT)"
fi
PFC_HASH_MID=$(sha256sum "$WORKSPACE/memory/pfc-state.json" | awk '{print $1}')
if [ "$PFC_HASH_BEFORE" = "$PFC_HASH_MID" ]; then
  pass "pfc still unchanged without --promote"
else
  fail "pfc still unchanged without --promote"
fi

# ── promote under caps ──────────────────────────────────────────────────────
section "propose-goals-promote"
POUT=$(bash "$CORE/executive/propose-goals.sh" --workspace "$WORKSPACE" --reflection "$REF_OUT" --promote --max-active 5 --max-promote 2 2>/tmp/pm_err.$$) || {
  cat /tmp/pm_err.$$ >&2
  fail "propose-goals promote exit"
  POUT="{}"
}
rm -f /tmp/pm_err.$$
ACTIVE=$(jq '[.goals[]? | select(.status=="active")] | length' "$WORKSPACE/memory/pfc-state.json")
if [ "$ACTIVE" -ge 1 ] && [ "$ACTIVE" -le 2 ]; then
  pass "promoted goals within max-promote=2 (active=$ACTIVE)"
else
  fail "promoted goals within max-promote=2 (active=$ACTIVE)"
fi
if echo "$POUT" | jq -e '(.promoted|length)>=1' >/dev/null; then
  pass "promote report non-empty"
else
  fail "promote report non-empty"
fi

# ── load gate blocks further promote when E high ────────────────────────────
section "executive-load-gate"
# Fill to max active then set high E
cat > "$WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.85, "band": "hard_ceiling_zone", "G": 2, "Q": 2, "I_sec": 5}
EOF
# Ensure we still have room structurally would promote, but E blocks
BEFORE_GATE=$(jq '[.goals[]? | select(.status=="active")] | length' "$WORKSPACE/memory/pfc-state.json")
GOUT=$(bash "$CORE/executive/propose-goals.sh" --workspace "$WORKSPACE" --reflection "$REF_OUT" --promote --max-active 10 --max-promote 3 2>/dev/null || echo "{}")
AFTER_GATE=$(jq '[.goals[]? | select(.status=="active")] | length' "$WORKSPACE/memory/pfc-state.json")
if [ "$BEFORE_GATE" -eq "$AFTER_GATE" ] && echo "$GOUT" | jq -e '.skipped_reason != null' >/dev/null 2>&1; then
  pass "high E blocks promote"
else
  # skipped_reason may be set even if...
  if echo "$GOUT" | jq -e '(.skipped_reason|type=="string") and (.promoted|length==0)' >/dev/null 2>&1; then
    pass "high E blocks promote"
  else
    fail "high E blocks promote (before=$BEFORE_GATE after=$AFTER_GATE out=$GOUT)"
  fi
fi

# ── full cycle entrypoint ───────────────────────────────────────────────────
section "run-executive-cycle"
# Reset load low; empty goals for clean cycle
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{"version":"1.0","lastUpdated":"","executiveLoad":0.2,"goals":[],"inhibitions":[],"decisionLog":[]}
EOF
cat > "$WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.25, "band": "underutilized", "G": 0, "Q": 2, "I_sec": 0}
EOF
if bash "$CORE/executive/run-executive-cycle.sh" --workspace "$WORKSPACE" >/tmp/cyc_out.$$ 2>/tmp/cyc_err.$$; then
  pass "run-executive-cycle exit 0"
else
  cat /tmp/cyc_err.$$ >&2
  fail "run-executive-cycle exit 0"
fi
rm -f /tmp/cyc_out.$$ /tmp/cyc_err.$$
if [ -f "$WORKSPACE/memory/executive/last-cycle.json" ]; then
  pass "last-cycle.json marker"
else
  fail "last-cycle.json marker"
fi
CYC_ACTIVE=$(jq '[.goals[]? | select(.status=="active")] | length' "$WORKSPACE/memory/pfc-state.json")
if [ "$CYC_ACTIVE" -ge 1 ]; then
  pass "cycle promoted at least one goal"
else
  fail "cycle promoted at least one goal"
fi

# ── skill wrapper resolves core ─────────────────────────────────────────────
section "skill-wrapper"
if WORKSPACE="$WORKSPACE" bash "$ROOT/skills/executive-function/scripts/run-cycle.sh" --no-promote >/dev/null 2>&1; then
  pass "skill run-cycle.sh --no-promote"
else
  # Without workspace core, suite-relative path should work in dev tree
  if [ -x "$ROOT/core/executive/run-executive-cycle.sh" ]; then
    # re-run with explicit path simulation: SCRIPT uses ../../../core from skills/...
    if WORKSPACE="$WORKSPACE" bash "$ROOT/skills/executive-function/scripts/run-cycle.sh" --no-promote; then
      pass "skill run-cycle.sh --no-promote"
    else
      fail "skill run-cycle.sh --no-promote"
    fi
  else
    fail "skill run-cycle.sh --no-promote"
  fi
fi

# ── manifest validation (skill + core executive) ────────────────────────────
section "manifests"
if bash "$CORE/schema/validate-manifest.sh" "$ROOT/skills/executive-function/capability-manifest.json"; then
  pass "executive-function skill manifest"
else
  fail "executive-function skill manifest"
fi
if bash "$CORE/schema/validate-manifest.sh" "$CORE/executive/capability-manifest.json"; then
  pass "core executive manifest"
else
  fail "core executive manifest"
fi

# ── KV cap contract still enforced via semaphore helper ─────────────────────
section "concurrency-contract"
# shellcheck source=/dev/null
source "$CORE/concurrency/semaphore.sh"
if semaphore_check_kv_cap 2048; then
  pass "KV 2048 allowed"
else
  fail "KV 2048 allowed"
fi
if ! semaphore_check_kv_cap 2049; then
  pass "KV 2049 rejected"
else
  fail "KV 2049 rejected"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Phase 2 harness: $PASSES passed, $FAILURES failed"
echo "========================================"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
