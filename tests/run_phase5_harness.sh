#!/bin/bash
# run_phase5_harness.sh — ROADMAP M4 goal-outcome loop regression.
# Covers:
#   * Goal injection: run_spawn's helpers read active PFC goals and augment
#     spawn task text with them.
#   * Goal-outcome recording: success marks goals complete, failure marks
#     them failed AND feeds ACC error memory (goal_failed pattern).
#   * Stale-goal deferral: past-deadline / untouched active goals defer.
#   * ACC calibration: decisionLog outcomes correlate with error patterns
#     into memory/acc-calibration.json.
#
# Uses an isolated temp WORKSPACE. Does not touch the real project tree.
#
# Usage: bash tests/run_phase5_harness.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
PASSES=0

pass() { echo "  PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
section() { echo ""; echo "=== $1 ==="; }

export WORKSPACE
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory/executive"

# ── Fixture PFC state with two active goals ─────────────────────────────────
section "fixture"
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "2026-08-04T00:00:00Z",
  "executiveLoad": 0.3,
  "goals": [
    {"id":"goal_a","description":"Ship the v2 dashboard","priority":0.9,"status":"active","deadline":"","createdAt":"2026-07-01T00:00:00Z"},
    {"id":"goal_b","description":"Refactor the memory index","priority":0.6,"status":"active","deadline":"2026-07-15T00:00:00Z","createdAt":"2026-06-01T00:00:00Z"}
  ],
  "inhibitions": [],
  "decisionLog": []
}
EOF
pass "fixture pfc-state written"

# ── 1. Goal injection helpers ───────────────────────────────────────────────
section "goal-injection"
python3 - "$ROOT/deep-brain-kernel.py" << 'PY' > /tmp/p5_inject.$$
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
goals = dbk._active_goal_descriptions()
aug = dbk._augment_spawn_task("Run the encoding pipeline", goals)
print(json.dumps({"goals": goals, "augmented": "Ship the v2 dashboard" in aug,
                  "task_preserved": aug.startswith("Run the encoding pipeline"),
                  "plain": dbk._augment_spawn_task("plain", [])}))
PY
INJ=$(cat /tmp/p5_inject.$$)
if echo "$INJ" | jq -e '(.goals|length)==2 and .goals[0]=="Ship the v2 dashboard"' >/dev/null; then
  pass "active goals read, priority-ordered (dashboard first)"
else
  fail "active goals read ($INJ)"
fi
if echo "$INJ" | jq -e '.augmented==true and .task_preserved==true' >/dev/null; then
  pass "spawn task text augmented with goal context"
else
  fail "spawn task text augmented ($INJ)"
fi
if echo "$INJ" | jq -e '.plain=="plain"' >/dev/null; then
  pass "no goals -> task unchanged"
else
  fail "no goals -> task unchanged ($INJ)"
fi
rm -f /tmp/p5_inject.$$

# ── 2. Outcome recording: success -> complete ───────────────────────────────
section "outcome-success"
WORKSPACE="$WORKSPACE" bash "$ROOT/core/executive/record-goal-outcome.sh" outcome \
  --goal-description "Ship the v2 dashboard" --outcome success --job p5test >/dev/null
STATUS_A=$(jq -r '.goals[] | select(.id=="goal_a") | .status' "$WORKSPACE/memory/pfc-state.json")
if [ "$STATUS_A" = "complete" ]; then
  pass "success marks goal complete"
else
  fail "success marks goal complete (status=$STATUS_A)"
fi
if jq -e '.goals[] | select(.id=="goal_a") | .completedAt != null' "$WORKSPACE/memory/pfc-state.json" >/dev/null; then
  pass "completedAt timestamp recorded"
else
  fail "completedAt timestamp recorded"
fi
if [ -f "$WORKSPACE/memory/executive/goal-outcomes.jsonl" ] && \
   grep -q '"goal_id":"goal_a"' "$WORKSPACE/memory/executive/goal-outcomes.jsonl"; then
  pass "outcome appended to goal-outcomes.jsonl"
else
  fail "outcome appended to goal-outcomes.jsonl"
fi

# ── 3. Outcome recording: failure -> failed + ACC feed ──────────────────────
section "outcome-failure"
mkdir -p "$WORKSPACE/skills/acc-error-memory/scripts"
cp "$ROOT/skills/acc-error-memory/scripts/log-error.sh" "$WORKSPACE/skills/acc-error-memory/scripts/log-error.sh" 2>/dev/null || true
# Use the real ACC log-error.sh via WORKSPACE-relative path resolution
WORKSPACE="$WORKSPACE" bash "$ROOT/core/executive/record-goal-outcome.sh" outcome \
  --goal-description "Refactor the memory index" --outcome failure --job p5test --evidence "index corrupt" >/dev/null
STATUS_B=$(jq -r '.goals[] | select(.id=="goal_b") | .status' "$WORKSPACE/memory/pfc-state.json")
if [ "$STATUS_B" = "failed" ]; then
  pass "failure marks goal failed"
else
  fail "failure marks goal failed (status=$STATUS_B)"
fi
if grep -q '"goal_id":"goal_b"' "$WORKSPACE/memory/executive/goal-outcomes.jsonl"; then
  pass "failure outcome appended"
else
  fail "failure outcome appended"
fi
# ACC feed: log-error.sh self-initializes acc-state.json; only runs if found
if [ -x "$ROOT/skills/acc-error-memory/scripts/log-error.sh" ]; then
  if [ -f "$WORKSPACE/memory/acc-state.json" ] && \
     jq -e '.activePatterns | has("goal_failed:Refactor the memory index")' "$WORKSPACE/memory/acc-state.json" >/dev/null 2>&1; then
    pass "failure fed ACC error memory (goal_failed pattern)"
  else
    fail "failure fed ACC error memory (acc-state: $(cat "$WORKSPACE/memory/acc-state.json" 2>/dev/null | head -c 200))"
  fi
else
  fail "ACC log-error.sh not found — cannot verify feed"
fi

# ── 3b. Relevance guard: task mismatch logs but does NOT flip status ───────
section "relevance-guard"
jq '.goals += [{"id":"goal_r","description":"Learn to play the piano","priority":0.3,"status":"active","deadline":"","createdAt":"2026-07-01T00:00:00Z"}]' \
  "$WORKSPACE/memory/pfc-state.json" > "$WORKSPACE/memory/pfc-state.json.tmp" && \
  mv "$WORKSPACE/memory/pfc-state.json.tmp" "$WORKSPACE/memory/pfc-state.json"
WORKSPACE="$WORKSPACE" bash "$ROOT/core/executive/record-goal-outcome.sh" outcome \
  --goal-description "Learn to play the piano" --outcome success --job p5test \
  --task "run database migration" >/dev/null
STATUS_R=$(jq -r '.goals[] | select(.id=="goal_r") | .status' "$WORKSPACE/memory/pfc-state.json")
if [ "$STATUS_R" = "active" ]; then
  pass "task mismatch: goal NOT auto-completed (stays active)"
else
  fail "task mismatch: goal NOT auto-completed (status=$STATUS_R)"
fi
if grep '"goal_id":"goal_r"' "$WORKSPACE/memory/executive/goal-outcomes.jsonl" | grep -q '"flipped":false'; then
  pass "task mismatch: outcome logged with flipped=false"
else
  fail "task mismatch: outcome logged with flipped=false"
fi

# ── 4. Stale-goal deferral ──────────────────────────────────────────────────
section "defer-stale"
# goal_b already marked failed; re-add a stale active goal to test deferral
jq '.goals += [{"id":"goal_c","description":"Old idea","priority":0.2,"status":"active","deadline":"2020-01-01T00:00:00Z","createdAt":"2019-01-01T00:00:00Z"}]' \
  "$WORKSPACE/memory/pfc-state.json" > "$WORKSPACE/memory/pfc-state.json.tmp" && \
  mv "$WORKSPACE/memory/pfc-state.json.tmp" "$WORKSPACE/memory/pfc-state.json"
WORKSPACE="$WORKSPACE" bash "$ROOT/core/executive/record-goal-outcome.sh" defer-stale --days 30 >/dev/null
STATUS_C=$(jq -r '.goals[] | select(.id=="goal_c") | .status' "$WORKSPACE/memory/pfc-state.json")
if [ "$STATUS_C" = "deferred" ]; then
  pass "past-deadline goal deferred"
else
  fail "past-deadline goal deferred (status=$STATUS_C)"
fi

# ── 5. ACC calibration from decisionLog ─────────────────────────────────────
section "acc-calibration"
# Seed an error pattern + decisionLog entries that overlap it
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{
  "version": "2.0",
  "activePatterns": {
    "memory index corruption": {"count": 2, "severity": "warning", "mitigation": "verify writes"}
  },
  "resolved": {},
  "stats": {"totalErrorsLogged": 2}
}
EOF
jq '.decisionLog = [
  {"chosen":"refactor memory index","context":"maintenance","reasoning":"memory index corruption risk","timestamp":"2026-08-01T00:00:00Z"},
  {"chosen":"ship dashboard","context":"planning","reasoning":"high confidence, straightforward path","timestamp":"2026-08-02T00:00:00Z"}
]' "$WORKSPACE/memory/pfc-state.json" > "$WORKSPACE/memory/pfc-state.json.tmp" && \
  mv "$WORKSPACE/memory/pfc-state.json.tmp" "$WORKSPACE/memory/pfc-state.json"

CAL=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/acc-error-memory/scripts/calibrate-decisions.sh" 2>/dev/null)
if echo "$CAL" | jq -e '.decisionsReviewed==2 and .errorLinkedDecisions==1' >/dev/null; then
  pass "calibration correlates decisionLog with error patterns (1/2 linked)"
else
  fail "calibration correlates decisionLog ($CAL)"
fi
if echo "$CAL" | jq -e '.flaggedUncertainty>=1 and .uncertaintyThatErrored>=1 and .uncertaintyCalibration==1.0' >/dev/null; then
  pass "uncertainty->error precision computed (flagged uncertainty that errored)"
else
  fail "uncertainty->error precision ($CAL)"
fi
if [ -f "$WORKSPACE/memory/acc-calibration.json" ]; then
  pass "calibration snapshot written to memory/acc-calibration.json"
else
  fail "calibration snapshot written"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Phase 5 harness: $PASSES passed, $FAILURES failed"
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
