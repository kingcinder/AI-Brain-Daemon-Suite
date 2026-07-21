#!/bin/bash
# evaluate-proposal.sh — Sandbox + regression evaluation for one proposal.
#
# 1. check-target
# 2. Copy suite tree to temp sandbox suite
# 3. apply-patch into sandbox suite
# 4. Run regression tests (default: phase1 harness subset or declared tests)
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
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
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
if [ -f "$BASELINE_METRICS" ]; then
  BASE_TS=$(jq -r '.task_success // 0.7' "$BASELINE_METRICS")
  BASE_LAT_SEC=$(jq -r '.latency_sec // .baseline_latency_sec // empty' "$BASELINE_METRICS")
  BASE_MEM=$(jq -r '.memory_kv_norm // 1.0' "$BASELINE_METRICS")
fi
if [ -z "$BASE_LAT_SEC" ] || [ "$BASE_LAT_SEC" = "null" ]; then
  # Measure baseline: time phase1 harness (or bash -n no-op suite) on unpatched suite
  echo "evaluate-proposal: measuring latency baseline..." >&2
  B0=$(date +%s%N)
  if [ -f "$SUITE_ROOT/tests/run_phase1_harness.sh" ]; then
    # Use a quick deterministic proxy: time bash -n of target scripts + phase1 if under 30s
    # Prefer full phase1 when available for realistic baseline
    set +e
    (cd "$SUITE_ROOT" && timeout 90 bash tests/run_phase1_harness.sh >/tmp/baseline_harness.out 2>&1)
    set -e
  else
    sleep 0.05
  fi
  B1=$(date +%s%N)
  BASE_LAT_SEC=$(python3 -c "print(round(($B1-$B0)/1e9, 4))")
  # Never store zero
  python3 -c "import sys; sys.exit(0 if float('$BASE_LAT_SEC')>0.01 else 1)" || BASE_LAT_SEC=0.05
  jq -nc --argjson ts "$BASE_TS" --argjson lat "$BASE_LAT_SEC" --argjson mem "$BASE_MEM" \
    '{task_success:$ts, latency_sec:$lat, memory_kv_norm:$mem, source:"evaluate-proposal-measured", measured_at:(now|todateiso8601)}' \
    > "$BASELINE_METRICS" 2>/dev/null || \
  python3 -c "import json,time; json.dump({'task_success':float('$BASE_TS'),'latency_sec':float('$BASE_LAT_SEC'),'memory_kv_norm':float('$BASE_MEM'),'source':'evaluate-proposal-measured','measured_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}, open('$BASELINE_METRICS','w'), indent=2)"
  echo "evaluate-proposal: baseline latency_sec=$BASE_LAT_SEC" >&2
fi
BASE_U=$(bash "$ROOT/core/utility/score-utility.sh" \
  --task-success "$BASE_TS" --resource-cost 0.2 --error-rate 0.0 --regression-penalty 0.0 | jq -r .U)

# Sandbox suite copy (skills + core scripts under evaluation — not full .git)
SB=$(mktemp -d "${TMPDIR:-/tmp}/aibrain-eval.XXXXXX")
cleanup() {
  rm -rf "$SB"
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

# Regression: run phase1 harness from sandbox suite if present
REG_RC=0
REG_OUT=""
START=$(date +%s%N)
set +e
if [ -f "$SB/suite/tests/run_phase1_harness.sh" ]; then
  REG_OUT=$(cd "$SB/suite" && bash tests/run_phase1_harness.sh 2>&1)
  REG_RC=$?
else
  # Fallback: syntax-check applied targets
  REG_OUT="no phase1 harness; bash -n targets"
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

REG_FAIL=0
[ "$REG_RC" -ne 0 ] && REG_FAIL=1

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
  REASON="regression_failed"
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
  python3 - "$WORKSPACE/memory/self-mod/proposals/${PID}.json" "$UTIL" "$THR" "$ACCEPTED" "$REASON" "$REG_RC" <<'PY'
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
      --proposal-id "$PID" --reason "sandbox_or_regression_failure:rc=$REG_RC" 2>/dev/null || echo '{}')
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
    --content "evaluate:$PID:U=$U:rc=$REG_RC" \
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
  --argjson reg_rc "$REG_RC" \
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
