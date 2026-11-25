#!/bin/bash
# run_phase9_harness.sh — ROADMAP M8 regression harness, M9 contract (2026-11-13).
#
# M8 made the M7 autonomy contract a real control consumed by
# run-pipeline.sh --autonomy-gate. M9 (Dither's order, 2026-11-13) moved the
# approval gate from the human to Juno: the autonomy mode and graduation
# review_mode are still computed and recorded in the run summary as
# evidence, but neither can block a deploy, defer a run, or queue a
# proposal for human approval.
#
# Covers:
#   * auto_mode + full_review → deploys (as before).
#   * --defer-gate NEVER defers under M9 — steward_mode + full_review runs
#     and deploys; no deferred summary, no autonomy.gate.deferred event.
#   * steward_mode + full_review → Juno approves: deploys, with provenance
#     autonomy.gate.deploy_allowed carrying approver:"juno" /
#     reason:"juno_approval_gate"; no deploy_blocked event.
#   * steward_mode + relaxed_review → deploys (unchanged).
#   * Missing autonomy-state.json → still reports steward_mode as the
#     evidence default, but blocks nothing: the proposal deploys.
#   * Back-compat: without --autonomy-gate the pipeline deploys as before
#     and writes no gate provenance event.
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

# ── M9: --defer-gate NEVER defers — steward + full_review runs + deploys ────
section "M9-defer-gate-never-defers"
# Fresh workspace slice to avoid deploy pollution from the auto_mode run
WD=$(mktemp -d)
mkdir -p "$WD/memory/self-mod"
cat > "$WD/memory/self-mod/graduation-streak.json" << 'EOF'
{
  "clean_streak": 3,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-08T00:00:00Z",
  "history": []
}
EOF
cat > "$WD/memory/self-mod/autonomy-state.json" << 'EOF'
{
  "mode": "steward_mode",
  "auto": false,
  "computed_at": "2026-08-08T00:00:00Z",
  "evidence": {"graduated": false, "clean_streak": 3, "unhealthy_jobs": 0, "auto_rollbacks_in_window": 0}
}
EOF
PROPD=$(make_proposal prop_m9_nodefer '#!/bin/bash
# demo
echo "hello-v2-nodefer"')
PIPED=$(WORKSPACE="$WD" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$WD" --proposal "$PROPD" \
  --autonomy-gate --defer-gate 2>/tmp/p9_def_err.$$) || {
  cat /tmp/p9_def_err.$$ >&2
  fail "pipeline exit 0 with --defer-gate in steward/full_review"
  PIPED="{}"
}
rm -f /tmp/p9_def_err.$$
if echo "$PIPED" | jq -e '.deferred != true and (.deploy.skipped != true) and .deploy.proposal_id=="prop_m9_nodefer" and .autonomy_mode=="steward_mode" and .review_mode=="full_review"' >/dev/null; then
  pass "--defer-gate: no deferral under M9 — run proceeded and deployed"
else
  fail "--defer-gate: no deferral under M9 ($PIPED)"
fi
if [ -f "$WD/memory/self-mod/pipeline-runs/latest.json" ] && jq -e '.deferred != true' "$WD/memory/self-mod/pipeline-runs/latest.json" >/dev/null 2>&1; then
  pass "--defer-gate: latest.json records a normal (non-deferred) run"
else
  fail "--defer-gate: latest.json non-deferred record ($PIPED)"
fi
if [ ! -f "$WD/memory/provenance/events.jsonl" ] || ! grep -q 'autonomy.gate.deferred' "$WD/memory/provenance/events.jsonl" 2>/dev/null; then
  pass "--defer-gate: no autonomy.gate.deferred provenance event"
else
  fail "--defer-gate: deferred provenance event written under M9 ($(cat "$WD/memory/provenance/events.jsonl" 2>/dev/null))"
fi
if grep -q 'hello-v2-nodefer' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "--defer-gate: deploy happened (content applied)"
else
  fail "--defer-gate: content not applied"
fi
rm -f "$PROPD"
rm -rf "$WD"

# ── M8: --defer-gate must NOT defer when auto_mode (contract wins) ──────────
section "M8-defer-gate-auto-mode-deploys"
WA=$(mktemp -d)
mkdir -p "$WA/memory/self-mod"
cat > "$WA/memory/self-mod/graduation-streak.json" << 'EOF'
{
  "clean_streak": 3,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-08T00:00:00Z",
  "history": []
}
EOF
cat > "$WA/memory/self-mod/autonomy-state.json" << 'EOF'
{
  "mode": "auto_mode",
  "auto": true,
  "computed_at": "2026-08-08T00:00:00Z",
  "evidence": {"graduated": true, "clean_streak": 25, "unhealthy_jobs": 0, "auto_rollbacks_in_window": 0}
}
EOF
PROPA=$(make_proposal prop_m8_deferauto '#!/bin/bash
# demo
echo "hello-v2-deferauto"')
PIPEA=$(WORKSPACE="$WA" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$WA" --proposal "$PROPA" \
  --autonomy-gate --defer-gate 2>/tmp/p9_defa_err.$$) || {
  cat /tmp/p9_defa_err.$$ >&2
  fail "pipeline exit 0 with --defer-gate in auto_mode"
  PIPEA="{}"
}
rm -f /tmp/p9_defa_err.$$
if echo "$PIPEA" | jq -e '.deferred != true and .deploy.proposal_id=="prop_m8_deferauto"' >/dev/null; then
  pass "--defer-gate: auto_mode still deploys (contract overrides deferral)"
else
  fail "--defer-gate: auto_mode deploy ($PIPEA)"
fi
if grep -q 'hello-v2-deferauto' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "--defer-gate auto_mode: content applied"
else
  fail "--defer-gate auto_mode: content applied"
fi
rm -f "$PROPA"
rm -rf "$WA"

# ── M9: steward_mode + full_review → Juno approves, deploy proceeds ─────────
section "M9-steward-full-review-juno-approves"
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
PROP2=$(make_proposal prop_m9_steward '#!/bin/bash
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
if echo "$PIPE2" | jq -e '(.deploy.skipped != true) and .deploy.proposal_id=="prop_m9_steward"' >/dev/null; then
  pass "steward_mode + full_review: Juno approved — pipeline deployed"
else
  fail "steward_mode + full_review: Juno approved — pipeline deployed ($PIPE2)"
fi
if echo "$PIPE2" | jq -e '.autonomy_mode=="steward_mode" and .review_mode=="full_review"' >/dev/null; then
  pass "summary reports autonomy_mode=steward_mode + review_mode=full_review"
else
  fail "summary reports steward/full_review ($PIPE2)"
fi
if grep -q 'hello-v2-steward' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "steward full_review: proposal content applied"
else
  fail "steward full_review: proposal content not applied"
fi
# Juno's gate decision is a provenance event, carrying her as approver.
if grep -q 'autonomy.gate.deploy_allowed' "$W2/memory/provenance/events.jsonl" 2>/dev/null && grep -q 'juno_approval_gate' "$W2/memory/provenance/events.jsonl" 2>/dev/null; then
  pass "steward full_review: provenance autonomy.gate.deploy_allowed with juno_approval_gate logged"
else
  fail "steward full_review: deploy_allowed/juno provenance missing ($(cat "$W2/memory/provenance/events.jsonl" 2>/dev/null || echo 'no events file'))"
fi
if [ -f "$W2/memory/provenance/events.jsonl" ] && grep -q 'autonomy.gate.deploy_blocked' "$W2/memory/provenance/events.jsonl" 2>/dev/null; then
  fail "steward full_review: deploy_blocked event written under M9"
else
  pass "steward full_review: no deploy_blocked event under M9"
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

# ── M9: missing autonomy-state → reports steward_mode, blocks nothing ───────
section "M9-missing-autonomy-state-does-not-block"
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
# NOTE: no autonomy-state.json written — summary defaults to steward_mode
# as the evidence record, but under M9 that default blocks nothing.
PROP4=$(make_proposal prop_m9_failsafe '#!/bin/bash
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
if echo "$PIPE4" | jq -e '.autonomy_mode=="steward_mode" and (.deploy.skipped != true) and .deploy.proposal_id=="prop_m9_failsafe"' >/dev/null; then
  pass "missing autonomy-state: reports steward_mode evidence default, deploy NOT blocked"
else
  fail "missing autonomy-state: steward_mode default, deploy not blocked ($PIPE4)"
fi
if grep -q 'hello-v2-failsafe' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "missing autonomy-state: content applied"
else
  fail "missing autonomy-state: content applied"
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
# A no-gate run makes no autonomy decision — it must NOT write an autonomy
# gate provenance event (the audit trail stays truthful: only real gate
# decisions are recorded).
if [ ! -f "$W5/memory/provenance/events.jsonl" ] || ! grep -q 'autonomy.gate' "$W5/memory/provenance/events.jsonl" 2>/dev/null; then
  pass "no gate: no autonomy provenance event written (no decision made)"
else
  fail "no gate: autonomy provenance event written without a gate ($(cat "$W5/memory/provenance/events.jsonl" 2>/dev/null))"
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
