#!/bin/bash
# evaluate-proposal.sh — Sandbox + regression evaluation for one proposal.
#
# 1. check-target
# 2. Copy suite tree to temp sandbox suite
# 3. apply-patch into sandbox suite
# 4. Run gates: regression sweep (verification-memory declared-test sweep,
#    phase1 fallback) + daemon job-table check (deep-brain-kernel.py --check)
# 5. Score utility from measured metrics
# 6. Compare to baseline metrics for rollback thresholds
#
# Usage:
#   evaluate-proposal.sh --proposal PATH.json [--suite-root PATH] [--timeout SEC]
# Env: WORKSPACE (for provenance / baseline metrics)

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
PROPOSAL=""
TIMEOUT="${SANDBOX_TIMEOUT:-180}"
THRESH="$SELF_DIR/thresholds.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proposal) PROPOSAL="$2"; shift 2 ;;
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Per-test timeout floor for the regression sweep (also used when measuring the
# baseline): honor the sandbox budget but never go below the verification
# region's own 300s default — a tight SANDBOX_TIMEOUT must not kill a
# legitimately-running harness and falsely reject a good proposal. Computed
# AFTER arg parsing so an explicit --timeout is honored.
GATE_TIMEOUT="$TIMEOUT"
if ! [ "$GATE_TIMEOUT" -ge 300 ] 2>/dev/null; then
  GATE_TIMEOUT=300
fi
# GNU coreutils timeout(1) is not guaranteed on macOS; run-declared-tests.sh has
# its own per-test timeout fallback, so skip the outer wrapper when absent.
if command -v timeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=1
else
  HAVE_TIMEOUT=0
fi

[ -f "$PROPOSAL" ] || { echo "evaluate requires --proposal" >&2; exit 2; }
PID=$(jq -r .proposal_id "$PROPOSAL")

CHECK_JSON=$(bash "$SELF_DIR/check-target.sh" --suite-root "$SUITE_ROOT" --proposal "$PROPOSAL" 2>/dev/null) || {
  # Checklist / target gate failure resets review-frequency clean streak
  WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" record-failure \
    --proposal-id "$PID" --reason "check-target-failed" >/dev/null 2>&1 || true
  echo "$CHECK_JSON" | jq -c '{proposal_id:"'"$PID"'", accepted:false, stage:"check-target", check:.}' 2>/dev/null \
    || echo "{\"proposal_id\":\"$PID\",\"accepted\":false,\"stage\":\"check-target\"}"
  exit 1
}

# Baseline metrics (from workspace if present)
# Spec: latency increase is relative to a measured baseline latency (seconds).
# If latency_sec is missing, measure a baseline regression run once (no patch)
# and persist it so latency_checked stays true thereafter.
BASE_TS=0.7
BASE_LAT_SEC=""
BASE_MEM=1.0
BASELINE_METRICS="$WORKSPACE/memory/self-mod/baseline-metrics.json"
mkdir -p "$WORKSPACE/memory/self-mod"
BASELINE_METHOD=""
if [ -f "$BASELINE_METRICS" ]; then
  BASE_TS=$(jq -r '.task_success // 0.7' "$BASELINE_METRICS")
  BASE_LAT_SEC=$(jq -r '.latency_sec // .baseline_latency_sec // empty' "$BASELINE_METRICS")
  BASE_MEM=$(jq -r '.memory_kv_norm // 1.0' "$BASELINE_METRICS")
  BASELINE_METHOD=$(jq -r '.method // ""' "$BASELINE_METRICS")
fi
# The regression gate is now the verification-memory declared-test sweep (or the
# phase1 harness on installs without the verification region). Baseline latency
# must be measured with the SAME workload as the candidate, or the latency rule
# compares apples to oranges — so re-measure when missing OR when the stored
# method is stale (e.g. a phase1-based baseline persisted before this upgrade).
SWEEP_SH="$SUITE_ROOT/skills/verification-memory/scripts/run-declared-tests.sh"
GATE_METHOD="phase1"
[ -f "$SWEEP_SH" ] && GATE_METHOD="verification-sweep"
if [ -z "$BASE_LAT_SEC" ] || [ "$BASE_LAT_SEC" = "null" ] || [ "$BASELINE_METHOD" != "$GATE_METHOD" ]; then
  echo "evaluate-proposal: measuring latency baseline ($GATE_METHOD)..." >&2
  BWS=$(mktemp -d "${TMPDIR:-/tmp}/aibrain-baseline.XXXXXX")
  B0=$(date +%s%N)
  if [ -f "$SWEEP_SH" ]; then
    # Sweep with an isolated WORKSPACE: it publishes signals and writes
    # verification state that must never land in the live brain. Outer timeout
    # 600 keeps a pathological baseline from stalling evaluation; a timeout here
    # only inflates the baseline (fail-safe for the latency rule). On systems
    # without GNU timeout, rely on the sweep's own per-test timeout.
    set +e
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
      (cd "$SUITE_ROOT" && WORKSPACE="$BWS" timeout 600 bash "$SWEEP_SH" --quiet --timeout "$GATE_TIMEOUT" >/tmp/baseline_sweep.out 2>&1)
    else
      (cd "$SUITE_ROOT" && WORKSPACE="$BWS" bash "$SWEEP_SH" --quiet --timeout "$GATE_TIMEOUT" >/tmp/baseline_sweep.out 2>&1)
    fi
    set -e
  elif [ -f "$SUITE_ROOT/tests/run_phase1_harness.sh" ]; then
    set +e
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
      (cd "$SUITE_ROOT" && timeout 90 bash tests/run_phase1_harness.sh >/tmp/baseline_harness.out 2>&1)
    else
      (cd "$SUITE_ROOT" && bash tests/run_phase1_harness.sh >/tmp/baseline_harness.out 2>&1)
    fi
    set -e
  else
    sleep 0.05
  fi
  B1=$(date +%s%N)
  rm -rf "$BWS"
  BASE_LAT_SEC=$(python3 -c "print(round(($B1-$B0)/1e9, 4))")
  # Never store zero
  python3 -c "import sys; sys.exit(0 if float('$BASE_LAT_SEC')>0.01 else 1)" || BASE_LAT_SEC=0.05
  jq -nc --argjson ts "$BASE_TS" --argjson lat "$BASE_LAT_SEC" --argjson mem "$BASE_MEM" --arg m "$GATE_METHOD" \
    '{task_success:$ts, latency_sec:$lat, memory_kv_norm:$mem, method:$m, source:"evaluate-proposal-measured", measured_at:(now|todateiso8601)}' \
    > "$BASELINE_METRICS" 2>/dev/null || \
  python3 -c "import json,time; json.dump({'task_success':float('$BASE_TS'),'latency_sec':float('$BASE_LAT_SEC'),'memory_kv_norm':float('$BASE_MEM'),'method':'$GATE_METHOD','source':'evaluate-proposal-measured','measured_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}, open('$BASELINE_METRICS','w'), indent=2)"
  echo "evaluate-proposal: baseline latency_sec=$BASE_LAT_SEC (method=$GATE_METHOD)" >&2
fi
BASE_U=$(bash "$ROOT/core/utility/score-utility.sh" \
  --task-success "$BASE_TS" --resource-cost 0.2 --error-rate 0.0 --regression-penalty 0.0 | jq -r .U)

# Sandbox suite copy (skills + core scripts under evaluation — not full .git)
SB=$(mktemp -d "${TMPDIR:-/tmp}/aibrain-eval.XXXXXX")
cleanup() {
  rm -rf "$SB"
  [ -n "${BWS:-}" ] && rm -rf "$BWS"
}
trap cleanup EXIT

mkdir -p "$SB/suite"
# Lightweight copy: skills + core + tests (enough to apply patch + run harnesses)
for d in skills core tests; do
  if [ -d "$SUITE_ROOT/$d" ]; then
    cp -a "$SUITE_ROOT/$d" "$SB/suite/"
  fi
done
# Minimal stubs for harness ROOT detection
if [ -f "$SUITE_ROOT/deep-brain-kernel.py" ]; then
  cp -a "$SUITE_ROOT/deep-brain-kernel.py" "$SB/suite/" 2>/dev/null || true
fi

APPLY=$(bash "$SELF_DIR/apply-patch.sh" --suite-root "$SB/suite" --proposal "$PROPOSAL") || {
  jq -nc --arg pid "$PID" --arg err "$APPLY" \
    '{proposal_id:$pid, accepted:false, stage:"apply-patch", error:$err}'
  exit 1
}

# Regression gate: run the verification region's manifest-driven sweep — every
# test each module declared in its capability-manifest.json — inside the sandbox
# suite, so a proposal that breaks ANY declared test is rejected before deploy.
# Falls back to the phase1 harness (older installs / minimal test fixtures),
# then to bash -n syntax checks of the applied targets.
#
# The sweep runs with an isolated WORKSPACE so sandbox state and signals never
# clobber the live brain's verification memory or signal log.
VERIFY_SH="$SB/suite/skills/verification-memory/scripts/run-declared-tests.sh"
REG_RC=0
REG_OUT=""
START=$(date +%s%N)
set +e
if [ -f "$VERIFY_SH" ]; then
  echo "evaluate-proposal: regression gate: verification-memory declared-test sweep" >&2
  REG_OUT=$(cd "$SB/suite" && WORKSPACE="$SB/ws" bash "$VERIFY_SH" --quiet --timeout "$GATE_TIMEOUT" 2>&1)
  REG_RC=$?
elif [ -f "$SB/suite/tests/run_phase1_harness.sh" ]; then
  # Fallback: phase1 harness (pre-verification-region installs / minimal fixtures)
  echo "evaluate-proposal: regression gate: phase1 harness (fallback)" >&2
  REG_OUT=$(cd "$SB/suite" && bash tests/run_phase1_harness.sh 2>&1)
  REG_RC=$?
else
  # Last resort: syntax-check applied targets
  echo "evaluate-proposal: regression gate: bash -n syntax check (no harness)" >&2
  REG_OUT="no verification region or phase1 harness; bash -n targets"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if [ -f "$SB/suite/$t" ] && [[ "$t" == *.sh ]]; then
      bash -n "$SB/suite/$t" 2>>"$SB/bashn.err"
      REG_RC=$((REG_RC + $?))
    fi
  done < <(jq -r '(.target_paths // .targets // [])[]?' "$PROPOSAL")
  [ -f "$SB/bashn.err" ] && REG_OUT=$(cat "$SB/bashn.err")
fi
set -e
END=$(date +%s%N)
ELAPSED_NS=$((END - START))
ELAPSED_SEC=$(python3 -c "print(round($ELAPSED_NS/1e9, 4))")

# Job-table gate: run deep-brain-kernel.py --check against the PATCHED sandbox
# suite (kernel + skills copies) so a proposal that breaks a daemon job target
# — deletes a script a job references (MISSING), or truncates it to empty
# (EXISTS-BUT-EMPTY; a `content` write on an existing file preserves its mode,
# so emptiness is the vector, not lost exec bit) — is rejected before deploy,
# not just at PR time. Minute collisions can't currently be introduced via
# self-mod (root-level deep-brain-kernel.py fails check-target's manifest
# rule), but this guards that path too. Runs AFTER the elapsed measurement so
# the gate's ~1s overhead never skews the latency rule (candidate vs
# sweep-only baseline). --check is read-only; WORKSPACE=$SB/suite makes
# SKILLS_DIR resolve the patched scripts. hermes presence is a host concern a
# proposal can't fix, so skip it — same semantics as the CI gate.
CK_RC=0
CK_OUT=""
if [ -f "$SB/suite/deep-brain-kernel.py" ]; then
  echo "evaluate-proposal: job-table gate: deep-brain-kernel.py --check" >&2
  set +e
  CK_OUT=$(cd "$SB/suite" && WORKSPACE="$SB/suite" DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1 python3 deep-brain-kernel.py --check 2>&1)
  CK_RC=$?
  set -e
else
  echo "evaluate-proposal: job-table gate: skipped (no deep-brain-kernel.py in sandbox suite)" >&2
fi

# Combined gate: the sweep OR the job-table check failing rejects the proposal.
REG_FAIL=0
[ "$REG_RC" -ne 0 ] && REG_FAIL=1
[ "$CK_RC" -ne 0 ] && REG_FAIL=1
# Combined rc for downstream records — sweep-first: only fall back to the
# check's rc when the sweep itself was green (a check failure with a green
# sweep is not a sweep rc=0 case).
GATE_RC=$REG_RC
[ "$GATE_RC" -eq 0 ] && [ "$CK_RC" -ne 0 ] && GATE_RC=$CK_RC
# Surface which gate(s) broke (REG_OUT holds the sweep's FAIL lines; CK_OUT the
# --check COLLISION/MISSING/NOT-EXECUTABLE lines)
if [ "$REG_FAIL" -ne 0 ]; then
  echo "evaluate-proposal: gates failed (reg_rc=$REG_RC ck_rc=$CK_RC):" >&2
  if [ "$REG_RC" -ne 0 ] && [ -n "$REG_OUT" ]; then
    echo "$REG_OUT" | tail -20 >&2
  fi
  if [ "$CK_RC" -ne 0 ] && [ -n "$CK_OUT" ]; then
    echo "job-table check problems:" >&2
    echo "$CK_OUT" | grep -E 'COLLISION|MISSING|NOT-EXECUTABLE|EMPTY|problem' | tail -20 >&2
  fi
fi

# Derive post metrics
# task_success: 1.0 if tests pass else 0.0 (binary for harness)
# resource_cost: normalize elapsed vs 60s cap
# error_rate: 1 if fail else 0
# regression_penalty: 1 if fail else 0
TS=$( [ "$REG_FAIL" -eq 0 ] && echo 1.0 || echo 0.0 )
RC_COST=$(python3 -c "print(min(1.0, max(0.0, float('$ELAPSED_SEC')/60.0)))")
ER=$( [ "$REG_FAIL" -eq 0 ] && echo 0.0 || echo 1.0 )
RP=$( [ "$REG_FAIL" -eq 0 ] && echo 0.0 || echo 1.0 )

UTIL=$(bash "$ROOT/core/utility/score-utility.sh" \
  --task-success "$TS" --resource-cost "$RC_COST" --error-rate "$ER" --regression-penalty "$RP")
U=$(echo "$UTIL" | jq -r .U)

# Rollback threshold checks vs baseline
python3 - "$THRESH" "$BASE_TS" "$TS" "${BASE_LAT_SEC:-}" "$ELAPSED_SEC" "$BASE_MEM" "$REG_FAIL" "$BASE_U" "$U" <<'PY' > "$SB/threshold.json"
import json,sys
th=json.loads(open(sys.argv[1]).read())["rollback"]
base_ts, ts = float(sys.argv[2]), float(sys.argv[3])
base_lat_raw, lat = sys.argv[4], float(sys.argv[5])
base_mem = float(sys.argv[6])
reg_fail = int(sys.argv[7])
base_u, u = float(sys.argv[8]), float(sys.argv[9])
# Only compute latency increase when a measured baseline latency_sec exists.
# Missing baseline → skip latency rule (do not treat unitless 1.0 as 1 second).
lat_increase = 0.0
lat_checked = False
if base_lat_raw not in ("", "null", "None"):
    base_lat = float(base_lat_raw)
    if base_lat > 0:
        lat_increase = (lat / base_lat - 1.0)
        lat_checked = True
mem_increase = 0.0  # offline eval has no sibling KV measure yet (documented deviation)
ts_decrease = base_ts - ts
breaches=[]
if ts_decrease > th["task_success_decrease_max"]:
    breaches.append({"rule":"task_success_decrease","value":ts_decrease,"max":th["task_success_decrease_max"]})
if lat_checked and lat_increase > th["latency_increase_max"]:
    breaches.append({"rule":"latency_increase","value":lat_increase,"max":th["latency_increase_max"]})
if mem_increase > th["memory_kv_increase_max"]:
    breaches.append({"rule":"memory_kv_increase","value":mem_increase,"max":th["memory_kv_increase_max"]})
if th.get("any_regression_failure") and reg_fail:
    breaches.append({"rule":"regression_failure","value":reg_fail})
print(json.dumps({
    "breaches": breaches,
    "rollback_required": len(breaches)>0,
    "metrics": {
        "task_success": ts,
        "latency_sec": lat,
        "latency_increase": lat_increase,
        "latency_checked": lat_checked,
        "memory_kv_increase": mem_increase,
        "task_success_decrease": ts_decrease,
        "regression_failed": bool(reg_fail),
        "baseline_U": base_u,
        "candidate_U": u,
    }
}, indent=2))
PY

THR=$(cat "$SB/threshold.json")
ROLLBACK=$(echo "$THR" | jq -r .rollback_required)

# Asymmetric graduation
GRAD=$(jq -r '.graduation' "$THRESH")
REQUIRE_IMPROVE=$(echo "$GRAD" | jq -r '.require_utility_improvement // true')
REQUIRE_SB=$(echo "$GRAD" | jq -r '.require_sandbox_success // true')

ACCEPTED=true
REASON=""
if [ "$REQUIRE_SB" = "true" ] && [ "$REG_FAIL" -ne 0 ]; then
  ACCEPTED=false
  if [ "$CK_RC" -ne 0 ] && [ "$REG_RC" -eq 0 ]; then
    # Only the job-table gate broke (sweep was green)
    REASON="job_table_failed"
  else
    REASON="regression_failed"
  fi
fi
if [ "$ROLLBACK" = "true" ]; then
  ACCEPTED=false
  REASON="${REASON:+$REASON;}rollback_threshold_breach"
fi
if [ "$REQUIRE_IMPROVE" = "true" ]; then
  # U must be strictly greater than baseline U
  BETTER=$(python3 -c "import sys; sys.exit(0 if float('$U') > float('$BASE_U') else 1)") && true || BETTER=1
  if ! python3 -c "import sys; sys.exit(0 if float('$U') > float('$BASE_U') else 1)"; then
    ACCEPTED=false
    REASON="${REASON:+$REASON;}utility_not_improved"
  fi
fi

# Optional sandbox-run wrapper for provenance (memory-side command)
# Keep lightweight: already evaluated in SB suite.

# Persist scores onto proposal if in store
if [ -f "$WORKSPACE/memory/self-mod/proposals/${PID}.json" ]; then
  python3 - "$WORKSPACE/memory/self-mod/proposals/${PID}.json" "$UTIL" "$THR" "$ACCEPTED" "$REASON" "$GATE_RC" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); util=json.loads(sys.argv[2]); thr=json.loads(sys.argv[3])
accepted=sys.argv[4]=="true"; reason=sys.argv[5]; rc=int(sys.argv[6])
d=json.loads(p.read_text())
d.setdefault("scores",{})
d["scores"]["post_utility"]=util.get("U")
d["scores"]["post_components"]=util.get("components")
d["scores"]["threshold_check"]=thr
d["evaluation"]={"accepted":accepted,"reason":reason,"regression_exit":rc}
d["status"]="accepted" if accepted else "rejected"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
fi

# Review-frequency graduation streak (v3.9/v4.0) — separate from U-vs-baseline acceptance.
# Clean = sandbox/regression passed AND no threshold rollback_required.
# Failure of sandbox, automated tests, or checklist-style threshold breach → reset to 0.
GRAD_JSON='{}'
if [ -x "$SELF_DIR/graduation-tracker.sh" ] || [ -f "$SELF_DIR/graduation-tracker.sh" ]; then
  if [ "$REG_FAIL" -ne 0 ]; then
    GRAD_JSON=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" record-failure \
      --proposal-id "$PID" --reason "sandbox_or_regression_failure:rc=$GATE_RC" 2>/dev/null || echo '{}')
  elif [ "$ROLLBACK" = "true" ]; then
    GRAD_JSON=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" record-failure \
      --proposal-id "$PID" --reason "threshold_or_checklist_failure" 2>/dev/null || echo '{}')
  elif [ "$ACCEPTED" = true ]; then
    GRAD_JSON=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" record-clean \
      --proposal-id "$PID" --note "evaluate_accepted" 2>/dev/null || echo '{}')
  else
    # Rejected for non-clean reasons (e.g. utility_not_improved) still resets streak:
    # not a "clean" proposal under review-frequency rules.
    GRAD_JSON=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" record-failure \
      --proposal-id "$PID" --reason "not_clean:${REASON:-rejected}" 2>/dev/null || echo '{}')
  fi
  GRAD_JSON=$(echo "$GRAD_JSON" | jq -c . 2>/dev/null || echo '{}')
fi

# Provenance
if [ -f "$ROOT/core/provenance/log-provenance.sh" ]; then
  WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" append \
    --proposal-id "$PID" \
    --content "evaluate:$PID:U=$U:rc=$GATE_RC" \
    --parent-hash "null" \
    --proposer "evaluate-proposal" \
    --sandbox-score "$( [ "$REG_FAIL" -eq 0 ] && echo 1 || echo 0 )" \
    --utility-score "$U" \
    --rollback-status "$( [ "$ACCEPTED" = true ] && echo none || echo pending )" \
    >/dev/null 2>&1 || true
fi

jq -nc \
  --arg pid "$PID" \
  --argjson accepted "$ACCEPTED" \
  --arg reason "$REASON" \
  --argjson utility "$UTIL" \
  --argjson threshold "$THR" \
  --argjson reg_rc "$GATE_RC" \
  --argjson elapsed "$ELAPSED_SEC" \
  --arg apply "$APPLY" \
  --arg base_u "$BASE_U" \
  --argjson graduation "$GRAD_JSON" \
  '{
    proposal_id: $pid,
    accepted: $accepted,
    reason: $reason,
    utility: $utility,
    baseline_U: ($base_u|tonumber),
    threshold_check: $threshold,
    regression_exit: $reg_rc,
    elapsed_sec: $elapsed,
    apply: ($apply|fromjson? // $apply),
    review_frequency_graduation: $graduation
  }'
# Exit 0 even if rejected (caller inspects accepted); exit 1 only on hard errors
exit 0
