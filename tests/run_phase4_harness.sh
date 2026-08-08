#!/bin/bash
# run_phase4_harness.sh — ROADMAP M1+M2 regression harness.
# Covers:
#   * M1 job registration: self_mod_proposal_cycle exists in the daemon's
#     JOBS table with a globally-unique minute and weekly (Sunday) cadence.
#   * M2 autonomy gate: full_review queues for human approval (deploy skipped
#     with reason), relaxed_review auto-deploys the accepted proposal.
#   * Back-compat: without --autonomy-gate the pipeline deploys as before.
#
# Uses an isolated temp suite + WORKSPACE. Does not touch the real project
# tree (deploy/rollback run only inside the temp suite).
#
# Usage: bash tests/run_phase4_harness.sh

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

# ── Build minimal suite under $SUITE ─────────────────────────────────────────
section "fixture-suite"
mkdir -p "$SUITE/skills/demo-mod/scripts" "$SUITE/core" "$SUITE/tests"
for d in self-mod utility locks snapshot provenance sandbox concurrency schema executive-load executive; do
  cp -a "$CORE/$d" "$SUITE/core/" 2>/dev/null || true
done
cp -a "$CORE/capability-registry.schema.json" "$SUITE/core/" 2>/dev/null || true

# Peripheral skill with manifest (regression harness always passes)
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

# Immutable core stubs (same as phase3 fixture)
mkdir -p "$SUITE/core/locks" "$SUITE/core/concurrency" "$SUITE/core/sandbox" "$SUITE/core/executive-load"
echo '# lock' > "$SUITE/core/locks/rwlock.sh"
echo '# sem' > "$SUITE/core/concurrency/semaphore.sh"
echo '# sand' > "$SUITE/core/sandbox/sandbox-run.sh"
echo '# eload' > "$SUITE/core/executive-load/calc-executive-load.sh"
pass "temp suite assembled"

# ── M1: job registration ─────────────────────────────────────────────────────
section "M1-job-registered"
python3 - "$ROOT/deep-brain-kernel.py" << 'PY' > /tmp/p4_jobcheck.$$
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk  # dataclass _is_type looks up cls.__module__ in sys.modules
spec.loader.exec_module(dbk)
jobs = dbk.JOBS
job = next((j for j in jobs if j.name == "self_mod_proposal_cycle"), None)
out = {"found": job is not None}
if job:
    out.update({
        "kind": job.kind,
        "minutes": job.minutes,
        "days": job.days,
        "target": job.target,
        "minute_unique": sum(1 for j in jobs for m in j.minutes.split(",") if m.strip() == job.minutes) == 1,
        "weekly": job.days == "6",
    })
print(json.dumps(out))
PY
JOB=$(cat /tmp/p4_jobcheck.$$)
if echo "$JOB" | jq -e '.found==true' >/dev/null; then
  pass "self_mod_proposal_cycle registered in JOBS table"
else
  fail "self_mod_proposal_cycle registered in JOBS table"
fi
if echo "$JOB" | jq -e '.kind=="direct" and .weekly==true and .minute_unique==true' >/dev/null; then
  pass "direct job, weekly (Sunday), globally-unique minute (minute $(echo "$JOB" | jq -r .minutes))"
else
  fail "direct/weekly/unique minute: $JOB"
fi
if echo "$JOB" | jq -e '.target=="self-mod-runner/scripts/proposal-cycle-tick.sh"' >/dev/null; then
  pass "targets self-mod-runner proposal-cycle-tick.sh"
else
  fail "target is proposal-cycle-tick.sh: $JOB"
fi
if [ -x "$ROOT/skills/self-mod-runner/scripts/proposal-cycle-tick.sh" ]; then
  pass "proposal-cycle-tick.sh exists and is executable"
else
  fail "proposal-cycle-tick.sh exists and is executable (chmod +x?)"
fi
rm -f /tmp/p4_jobcheck.$$

# ── Legal proposal helper (accepted by evaluate: U vs baseline 0.7) ─────────
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

run_pipeline() {
  # run_pipeline <proposal-file> [--autonomy-gate]
  local prop="$1"; shift
  WORKSPACE="$WORKSPACE" bash "$SM/run-pipeline.sh" \
    --suite-root "$SUITE" --workspace "$WORKSPACE" --proposal "$prop" "$@"
}

set_review_mode() {
  # set_review_mode <full_review|relaxed_review>
  # graduation-tracker derives review_mode from clean_streak vs target (20)
  local mode="$1"
  local streak=0
  [ "$mode" = "relaxed_review" ] && streak=25
  mkdir -p "$WORKSPACE/memory/self-mod"
  cat > "$WORKSPACE/memory/self-mod/graduation-streak.json" << EOF
{
  "clean_streak": $streak,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-04T00:00:00Z",
  "history": []
}
EOF
}

# ── M2: full_review → human approval required (no auto-deploy) ──────────────
section "M2-full-review-blocks-deploy"
set_review_mode full_review
PROP=$(make_proposal prop_autonomy_full '#!/bin/bash
# demo
echo "hello-v2-full"')
PIPE=$(run_pipeline "$PROP" --autonomy-gate 2>/tmp/p4_fr_err.$$) || {
  cat /tmp/p4_fr_err.$$ >&2
  fail "pipeline exit 0 in full_review"
  PIPE="{}"
}
rm -f /tmp/p4_fr_err.$$
if echo "$PIPE" | jq -e '.deploy.skipped==true and .deploy.reason=="full_review_human_approval_required" and .deploy.review_mode=="full_review"' >/dev/null; then
  pass "full_review: deploy skipped with human-approval reason"
else
  fail "full_review: deploy skipped with reason ($PIPE)"
fi
if echo "$PIPE" | jq -e '.review_mode=="full_review" and .autonomy_gate==true' >/dev/null; then
  pass "summary reports autonomy_gate + full_review"
else
  fail "summary reports autonomy_gate + full_review ($PIPE)"
fi
if grep -q 'hello-v1' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "full_review: target file unchanged (no auto-deploy)"
else
  fail "full_review: target file unchanged (got $(cat "$SUITE/skills/demo-mod/scripts/hello.sh"))"
fi
rm -f "$PROP"

# ── M2: relaxed_review → auto-deploy accepted proposal ──────────────────────
section "M2-relaxed-review-auto-deploys"
# Fresh workspace slice to avoid store/deploy pollution from the full_review run
WORKSPACE2=$(mktemp -d)
mkdir -p "$WORKSPACE2/memory/self-mod"
cat > "$WORKSPACE2/memory/self-mod/graduation-streak.json" << 'EOF'
{
  "clean_streak": 25,
  "clean_streak_target": 20,
  "last_event": "harness",
  "last_updated": "2026-08-04T00:00:00Z",
  "review_mode": "relaxed_review",
  "history": []
}
EOF
PROP2=$(make_proposal prop_autonomy_relaxed '#!/bin/bash
# demo
echo "hello-v2-relaxed"')
PIPE2=$(WORKSPACE="$WORKSPACE2" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$WORKSPACE2" --proposal "$PROP2" \
  --autonomy-gate 2>/tmp/p4_rx_err.$$) || {
  cat /tmp/p4_rx_err.$$ >&2
  fail "pipeline exit 0 in relaxed_review"
  PIPE2="{}"
}
rm -f /tmp/p4_rx_err.$$
if echo "$PIPE2" | jq -e '.review_mode=="relaxed_review" and (.deploy.skipped != true)' >/dev/null; then
  pass "relaxed_review: pipeline deployed (not skipped)"
else
  fail "relaxed_review: pipeline deployed ($PIPE2)"
fi
if echo "$PIPE2" | jq -e '.deploy.proposal_id=="prop_autonomy_relaxed"' >/dev/null; then
  pass "relaxed_review: deploy record for accepted proposal"
else
  fail "relaxed_review: deploy record ($PIPE2)"
fi
if grep -q 'hello-v2-relaxed' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "relaxed_review: content applied to suite"
else
  fail "relaxed_review: content applied (got $(cat "$SUITE/skills/demo-mod/scripts/hello.sh"))"
fi
if [ -f "$WORKSPACE2/memory/self-mod/deploys/prop_autonomy_relaxed.json" ]; then
  pass "relaxed_review: deploy record file written"
else
  fail "relaxed_review: deploy record file written"
fi
rm -f "$PROP2"
rm -rf "$WORKSPACE2"

# ── Back-compat: no gate → deploys (unchanged Phase 3 behavior) ─────────────
section "backcompat-no-gate"
WORKSPACE3=$(mktemp -d)
mkdir -p "$WORKSPACE3/memory"
PROP3=$(make_proposal prop_autonomy_nogate '#!/bin/bash
# demo
echo "hello-v2-nogate"')
PIPE3=$(WORKSPACE="$WORKSPACE3" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$WORKSPACE3" --proposal "$PROP3" \
  2>/tmp/p4_ng_err.$$) || {
  cat /tmp/p4_ng_err.$$ >&2
  fail "pipeline exit 0 without gate"
  PIPE3="{}"
}
rm -f /tmp/p4_ng_err.$$
if echo "$PIPE3" | jq -e '.autonomy_gate==false and (.deploy.skipped != true)' >/dev/null; then
  pass "no gate: deploys as before (autonomy_gate=false)"
else
  fail "no gate: deploys as before ($PIPE3)"
fi
if grep -q 'hello-v2-nogate' "$SUITE/skills/demo-mod/scripts/hello.sh"; then
  pass "no gate: content applied"
else
  fail "no gate: content applied"
fi
rm -f "$PROP3"
rm -rf "$WORKSPACE3"

# ── M1: tick script smoke test (scheduled cycle degrades gracefully) ──────
section "M1-tick-smoke"
# Fresh empty workspace: LLM generation fails fast (no local server), pipeline
# continues with an empty store, writes a run summary, and exits 0.
WS_TICK=$(mktemp -d)
mkdir -p "$WS_TICK/memory"
if WORKSPACE="$WS_TICK" bash "$ROOT/skills/self-mod-runner/scripts/proposal-cycle-tick.sh" \
  >/tmp/p4_tick_out.$$ 2>/tmp/p4_tick_err.$$; then
  pass "tick script exits 0 on empty workspace (LLM gen degrades gracefully)"
else
  cat /tmp/p4_tick_err.$$ >&2
  fail "tick script exits 0 on empty workspace (got rc=$?)"
fi
rm -f /tmp/p4_tick_out.$$ /tmp/p4_tick_err.$$
if ls "$WS_TICK/memory/self-mod/pipeline-runs/latest.json" >/dev/null 2>&1; then
  pass "tick run writes pipeline-runs/latest.json"
else
  fail "tick run writes pipeline-runs/latest.json"
fi
rm -rf "$WS_TICK"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Phase 4 harness: $PASSES passed, $FAILURES failed"
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
