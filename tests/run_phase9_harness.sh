#!/bin/bash
# run_phase9_harness.sh — ROADMAP M8 regression harness.
#
# M8 makes the M7 autonomy contract a real control: run-pipeline.sh
# --autonomy-gate now consumes memory/self-mod/autonomy-state.json (written by
# deep-brain-kernel.py --autonomy) alongside the M2 graduation review_mode.
#
# Covers:
#   * auto_mode → pipeline may auto-deploy the accepted proposal EVEN IF the
#     graduation streak is in full_review (the M7 contract: in auto-mode the
#     human is consulted only for direction, immutable exemptions, incidents).
#   * steward_mode + full_review → deploy skipped, human approval required
#     (M2 behavior preserved).
#   * steward_mode + relaxed_review → auto-deploys (M2 behavior preserved).
#   * Missing/unreadable autonomy-state.json → fail-safe steward_mode
#     (never over-grant autonomy on absent evidence).
#   * Back-compat: without --autonomy-gate the pipeline deploys as before.
#
# Uses an isolated temp suite + WORKSPACE. Does not touch the real project
# tree (deploy/rollback run only inside the temp suite).
#
# Usage: bash tests/run_phase9_harness.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
SM="$CORE/self-mod"
FAILURES=0
PASSES=0

pass() { echo "  PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
section() { echo ""; echo "=== $1 ==="; }

export WORKSPACE
WORKSPACE=$(mktemp -d)
SUITE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE" "$SUITE"' EXIT

mkdir -p "$WORKSPACE/memory"
chmod +x "$SM"/*.sh 2>/dev/null || true

# ── Build minimal suite under $SUITE (mirrors phase3/phase4 fixture) ────────
section "fixture-suite"
mkdir -p "$SUITE/skills/demo-mod/scripts" "$SUITE/core" "$SUITE/tests"
for d in self-mod utility locks snapshot provenance sandbox concurrency schema executive-load executive; do
  cp -a "$CORE/$d" "$SUITE/core/" 2>/dev/null || true
done
cp -a "$CORE/capability-registry.schema.json" "$SUITE/core/" 2>/dev/null || true

cat > "$SUITE/skills/demo-mod/capability-manifest.json" << 'EOF'
{
  "schema": 1,
  "module": "demo-mod",
  "version": "0.1.0",
  "capabilities": ["demo"],
  "inputs": [],
  "outputs": [{"name": "note", "type": "state_write", "target": "memory/demo-note.txt"}],
  "side_effects": ["filesystem_write"],
  "dependencies": [],
  "tests": [{"path": "tests/run_phase1_harness.sh", "kind": "regression"}],
  "immutable": false
}
EOF
cat > "$SUITE/skills/demo-mod/scripts/hello.sh" << 'EOF'
#!/bin/bash
# demo peripheral script
echo "hello-v1"
EOF
chmod +x "$SUITE/skills/demo-mod/scripts/hello.sh"

cat > "$SUITE/tests/run_phase1_harness.sh" << 'EOF'
#!/bin/bash
echo "stub phase1: ok"
exit 0
EOF
chmod +x "$SUITE/tests/run_phase1_harness.sh"

mkdir -p "$SUITE/core/locks" "$SUITE/core/concurrency" "$SUITE/core/sandbox" "$SUITE/core/executive-load"
echo '# lock' > "$SUITE/core/locks/rwlock.sh"
echo '# sem' > "$SUITE/core/concurrency/semaphore.sh"
echo '# sand' > "$SUITE/core/sandbox/sandbox-run.sh"
echo '# eload' > "$SUITE/core/executive-load/calc-executive-load.sh"
pass "temp suite assembled"

# ── Helpers ─────────────────────────────────────────────────────────────────
make_proposal() {
  # make_proposal <id> <content>
  local id="$1" content="$2"
  local f; f=$(mktemp)
  cat > "$f" << EOF
{
  "proposal_id": "$id",
  "module": "demo-mod",
  "target_paths": ["skills/demo-mod/scripts/hello.sh"],
  "content": $(printf '%s' "$content" | jq -Rs .),
  "estimated_components": {
    "task_success": 0.9,
    "resource_cost": 0.1,
    "error_rate": 0.05,
    "regression_penalty": 0.0
  }
}
EOF
  echo "$f"
}

set_review_mode() {
  # set_review_mode <full_review|relaxed_review>
  local mode="$1"
  local streak=0
  [ "$mode" = "relaxed_review" ] && streak=25
  mkdir -p "$WORKSPACE/memory/self-mod"
  cat > "$WORKSPACE/memory/self-mod/graduation-streak.json" << EOF
{
  "clean_streak": $streak,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-08T00:00:00Z",
  "history": []
}
EOF
}

set_autonomy_mode() {
  # set_autonomy_mode <auto_mode|steward_mode>
  local mode="$1"
  mkdir -p "$WORKSPACE/memory/self-mod"
  cat > "$WORKSPACE/memory/self-mod/autonomy-state.json" << EOF
{
  "mode": "$mode",
  "auto": $([ "$mode" = "auto_mode" ] && echo true || echo false),
  "computed_at": "2026-08-08T00:00:00Z",
  "evidence": {
    "graduated": $([ "$mode" = "auto_mode" ] && echo true || echo false),
    "clean_streak": $([ "$mode" = "auto_mode" ] && echo 25 || echo 7),
    "clean_streak_target": 20,
    "unhealthy_jobs": 0,
    "auto_rollbacks_in_window": 0,
    "window_days": 30,
    "max_auto_rollbacks": 3
  }
}
EOF
}

run_pipeline() {
  # run_pipeline <proposal-file> [--autonomy-gate]
  local prop="$1"; shift
  WORKSPACE="$WORKSPACE" bash "$SM/run-pipeline.sh" \
    --suite-root "$SUITE" --workspace "$WORKSPACE" --proposal "$prop" "$@"
}

# ── M8: auto_mode auto-deploys even in full_review ──────────────────────────
section "M8-auto-mode-auto-deploys"
set_review_mode full_review
set_autonomy_mode auto_mode
PROP=$(make_proposal prop_m8_auto '#!/bin/bash
# demo
echo "hello-v2-auto"')
PIPE=$(run_pipeline "$PROP" --autonomy-gate 2>/tmp/p9_auto_err.$$) || {
  cat /tmp/p9_auto_err.$$ >&2
  fail "pipeline exit 0 in auto_mode"
  PIPE="{}"
}
rm -f /tmp/p9_auto_err.$$
if echo "$PIPE" | jq -e '.autonomy_mode=="auto_mode"' >/dev/null; then
  pass "summary reports autonomy_mode=auto_mode"
else
  fail "summary reports autonomy_mode=auto_mode ($PIPE)"
fi
if echo "$PIPE" | jq -e '.deploy.skipped != true and .deploy.proposal_id=="prop_m8_auto"' >/dev/null; then
  pass "auto_mode: pipeline auto-deployed despite full_review streak"
else
  fail "auto_mode: pipeline auto-deployed despite full_review ($PIPE)"
fi
if grep -q 'hello-v2-auto' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "auto_mode: content applied to suite"
else
  fail "auto_mode: content applied (got $(cat "$SUITE/skills/demo-mod/scripts/hello.sh"))"
fi
rm -f "$PROP"

# ── M8: steward_mode + full_review → human approval required (M2 preserved) ─
section "M8-steward-full-review-blocks"
# Fresh workspace slice to avoid deploy pollution from the auto_mode run
W2=$(mktemp -d)
mkdir -p "$W2/memory/self-mod"
cat > "$W2/memory/self-mod/graduation-streak.json" << 'EOF'
{
  "clean_streak": 3,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-08T00:00:00Z",
  "history": []
}
EOF
cat > "$W2/memory/self-mod/autonomy-state.json" << 'EOF'
{
  "mode": "steward_mode",
  "auto": false,
  "computed_at": "2026-08-08T00:00:00Z",
  "evidence": {"graduated": false, "clean_streak": 3, "unhealthy_jobs": 0, "auto_rollbacks_in_window": 0}
}
EOF
PROP2=$(make_proposal prop_m8_steward '#!/bin/bash
# demo
echo "hello-v2-steward"')
PIPE2=$(WORKSPACE="$W2" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$W2" --proposal "$PROP2" \
  --autonomy-gate 2>/tmp/p9_stew_err.$$) || {
  cat /tmp/p9_stew_err.$$ >&2
  fail "pipeline exit 0 in steward_mode"
  PIPE2="{}"
}
rm -f /tmp/p9_stew_err.$$
if echo "$PIPE2" | jq -e '.deploy.skipped==true and .deploy.reason=="full_review_human_approval_required" and .deploy.autonomy_mode=="steward_mode"' >/dev/null; then
  pass "steward_mode + full_review: deploy skipped with human-approval reason + autonomy_mode"
else
  fail "steward_mode + full_review: deploy skipped with reason ($PIPE2)"
fi
if echo "$PIPE2" | jq -e '.autonomy_mode=="steward_mode" and .review_mode=="full_review"' >/dev/null; then
  pass "summary reports autonomy_mode=steward_mode + review_mode=full_review"
else
  fail "summary reports steward/full_review ($PIPE2)"
fi
# The suite already carries hello-v2-auto from the auto_mode section — the
# correct invariant here is that THIS steward/full_review run did NOT apply its
# own proposal content (hello-v2-steward), not that the file is pristine.
if ! grep -q 'hello-v2-steward' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "steward full_review: proposal content NOT applied (no auto-deploy)"
else
  fail "steward full_review: proposal content applied despite block"
fi
rm -f "$PROP2"
rm -rf "$W2"

# ── M8: steward_mode + relaxed_review → auto-deploys (M2 preserved) ─────────
section "M8-steward-relaxed-deploys"
W3=$(mktemp -d)
mkdir -p "$W3/memory/self-mod"
cat > "$W3/memory/self-mod/graduation-streak.json" << 'EOF'
{
  "clean_streak": 25,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-08T00:00:00Z",
  "review_mode": "relaxed_review",
  "history": []
}
EOF
cat > "$W3/memory/self-mod/autonomy-state.json" << 'EOF'
{
  "mode": "steward_mode",
  "auto": false,
  "computed_at": "2026-08-08T00:00:00Z",
  "evidence": {"graduated": false, "clean_streak": 25, "unhealthy_jobs": 0, "auto_rollbacks_in_window": 0}
}
EOF
PROP3=$(make_proposal prop_m8_relaxed '#!/bin/bash
# demo
echo "hello-v2-relaxed"')
PIPE3=$(WORKSPACE="$W3" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$W3" --proposal "$PROP3" \
  --autonomy-gate 2>/tmp/p9_rel_err.$$) || {
  cat /tmp/p9_rel_err.$$ >&2
  fail "pipeline exit 0 in steward relaxed"
  PIPE3="{}"
}
rm -f /tmp/p9_rel_err.$$
if echo "$PIPE3" | jq -e '.deploy.skipped != true and .deploy.proposal_id=="prop_m8_relaxed"' >/dev/null; then
  pass "steward_mode + relaxed_review: pipeline deployed"
else
  fail "steward_mode + relaxed_review: pipeline deployed ($PIPE3)"
fi
if grep -q 'hello-v2-relaxed' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "steward relaxed: content applied"
else
  fail "steward relaxed: content applied"
fi
rm -f "$PROP3"
rm -rf "$W3"

# ── M8: missing autonomy-state → fail-safe steward_mode ─────────────────────
section "M8-missing-autonomy-state-fails-safe"
W4=$(mktemp -d)
mkdir -p "$W4/memory/self-mod"
cat > "$W4/memory/self-mod/graduation-streak.json" << 'EOF'
{
  "clean_streak": 0,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-08T00:00:00Z",
  "history": []
}
EOF
# NOTE: no autonomy-state.json written — pipeline must default to steward_mode
PROP4=$(make_proposal prop_m8_failsafe '#!/bin/bash
# demo
echo "hello-v2-failsafe"')
PIPE4=$(WORKSPACE="$W4" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$W4" --proposal "$PROP4" \
  --autonomy-gate 2>/tmp/p9_fs_err.$$) || {
  cat /tmp/p9_fs_err.$$ >&2
  fail "pipeline exit 0 with missing autonomy state"
  PIPE4="{}"
}
rm -f /tmp/p9_fs_err.$$
if echo "$PIPE4" | jq -e '.autonomy_mode=="steward_mode" and .deploy.skipped==true' >/dev/null; then
  pass "missing autonomy-state: fail-safe steward_mode, deploy blocked"
else
  fail "missing autonomy-state: fail-safe steward_mode ($PIPE4)"
fi
rm -f "$PROP4"
rm -rf "$W4"

# ── Back-compat: no gate → deploys (unchanged Phase 3 behavior) ─────────────
section "backcompat-no-gate"
W5=$(mktemp -d)
mkdir -p "$W5/memory"
PROP5=$(make_proposal prop_m8_nogate '#!/bin/bash
# demo
echo "hello-v2-nogate"')
PIPE5=$(WORKSPACE="$W5" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$W5" --proposal "$PROP5" \
  2>/tmp/p9_ng_err.$$) || {
  cat /tmp/p9_ng_err.$$ >&2
  fail "pipeline exit 0 without gate"
  PIPE5="{}"
}
rm -f /tmp/p9_ng_err.$$
if echo "$PIPE5" | jq -e '.autonomy_gate==false and (.deploy.skipped != true)' >/dev/null; then
  pass "no gate: deploys as before (autonomy_gate=false)"
else
  fail "no gate: deploys as before ($PIPE5)"
fi
if echo "$PIPE5" | jq -e '.autonomy_mode=="" or .autonomy_mode==null' >/dev/null; then
  pass "no gate: autonomy_mode unset (not consumed)"
else
  fail "no gate: autonomy_mode unset ($PIPE5)"
fi
rm -f "$PROP5"
rm -rf "$W5"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Phase 9 harness: $PASSES passed, $FAILURES failed"
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
