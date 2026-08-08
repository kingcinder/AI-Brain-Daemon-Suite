#!/bin/bash
# run-pipeline.sh — Canonical Phase 3 self-modification pipeline orchestrator.
#
# 1. Baseline snapshot + metrics
# 2. Load proposals (store status=queued, or --proposal / --proposals-dir)
# 3. Rank by Utility Function
# 4. Evaluate top-K (sandbox copy + regression)
# 5. Accept/reject (asymmetric graduation)
# 6. Deploy first accepted under RWLock + divergence
# 7. Register for continuous monitoring
#
# Usage:
#   run-pipeline.sh [--workspace PATH] [--suite-root PATH] [--top-k N]
#                   [--proposal PATH] [--proposals-dir DIR]
#                   [--no-deploy] [--dry-run]
#                   [--autonomy-gate] [--defer-gate]
#
# --autonomy-gate (ROADMAP M2 + M8): reads graduation-tracker
#   review-frequency and, under the M8 autonomy contract, the persisted
#   autonomy mode (memory/self-mod/autonomy-state.json, written by
#   deep-brain-kernel.py --autonomy). In auto_mode the pipeline may auto-deploy
#   accepted proposals on its own schedule (human consulted only for direction,
#   immutable exemptions, and incidents); in steward_mode only relaxed_review
#   may auto-deploy — full_review queues for human approval (deploy.skipped
#   with a reason). A missing/unreadable autonomy-state.json is treated as
#   steward_mode (fail-safe: never over-grant autonomy on absent evidence).
#   Without this flag, behavior is unchanged (deploy first accepted proposal).
#
# --defer-gate (weekly cycle): when combined with --autonomy-gate, a
#   steward_mode + full_review contract DEFERS the whole run — the pipeline
#   exits 0 early with a deferred summary instead of churning through
#   baseline/generate/rank/evaluate only to skip the deploy at the end. The
#   weekly cycle defers until the human either grants auto_mode or relaxes
#   review; the deferred decision is recorded in pipeline-runs and as a
#   provenance event (autonomy.gate.deferred).
#
# Does not modify Immutable Core modules. Pipeline code under core/self-mod
# is never a legal proposal target.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
TOP_K=""
PROPOSAL=""
PROP_DIR=""
NO_DEPLOY=0
DRY=0
GENERATE_LLM=0
AUTONOMY_GATE=0
DEFER_GATE=0
LLM_MODULE=""
LLM_PROVIDER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --top-k) TOP_K="$2"; shift 2 ;;
    --proposal) PROPOSAL="$2"; shift 2 ;;
    --proposals-dir) PROP_DIR="$2"; shift 2 ;;
    --no-deploy) NO_DEPLOY=1; shift ;;
    --dry-run) DRY=1; NO_DEPLOY=1; shift ;;
    --generate-llm) GENERATE_LLM=1; shift ;;
    --autonomy-gate) AUTONOMY_GATE=1; shift ;;
    --defer-gate) DEFER_GATE=1; shift ;;
    --llm-module) LLM_MODULE="$2"; shift 2 ;;
    --llm-provider) LLM_PROVIDER="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

export WORKSPACE
mkdir -p "$WORKSPACE/memory/self-mod/proposals" \
         "$WORKSPACE/memory/self-mod/deploys" \
         "$WORKSPACE/memory/self-mod/pipeline-runs"

# ── 0. Defer gate (weekly cycle): steward_mode + full_review defers early ───
# The cycle passes --defer-gate; a direct --proposal invocation without it
# keeps the M2 skip-deploy behavior (proposal still evaluated, then queued
# for human approval). With the flag, the contract is consulted BEFORE any
# baseline/generate/rank/evaluate churn, and a steward_mode + full_review
# contract defers the entire run: explicit deferred summary in pipeline-runs
# + a provenance event, exit 0 (a defer is a successful, auditable no-op,
# not a failure — the daemon must not flag the weekly cycle as broken).
# --defer-gate is documented as "when combined with --autonomy-gate"; require
# both so a lone --defer-gate can never silently change deploy behavior.
if [ "$DEFER_GATE" -eq 1 ] && [ "$AUTONOMY_GATE" -eq 1 ]; then
  DEFER_RM=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" review-frequency \
    2>/dev/null | jq -r '.review_mode // "full_review"' 2>/dev/null || echo "full_review")
  DEFER_RM="${DEFER_RM:-full_review}"
  DEFER_AM=$(jq -r '.mode // "steward_mode"' "$WORKSPACE/memory/self-mod/autonomy-state.json" 2>/dev/null || echo "steward_mode")
  DEFER_AM="${DEFER_AM:-steward_mode}"
  if [ "$DEFER_AM" != "auto_mode" ] && [ "$DEFER_RM" != "relaxed_review" ]; then
    TS_DEF=$(date -u +"%Y%m%dT%H%M%SZ")
    DEF_SUMMARY=$(jq -nc --arg ts "$TS_DEF" --arg am "$DEFER_AM" --arg rm "$DEFER_RM" \
      '{pipeline:"phase3-self-mod", timestamp:$ts, autonomy_gate:true, deferred:true, reason:"steward_full_review_deferred", autonomy_mode:$am, review_mode:$rm}')
    echo "$DEF_SUMMARY" > "$WORKSPACE/memory/self-mod/pipeline-runs/run_${TS_DEF}.json"
    echo "$DEF_SUMMARY" | tee "$WORKSPACE/memory/self-mod/pipeline-runs/latest.json"
    if [ -f "$ROOT/core/provenance/log-provenance.sh" ]; then
      WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" event \
        --event "autonomy.gate.deferred" --actor "run-pipeline" \
        --detail "$(jq -nc --arg am "$DEFER_AM" --arg rm "$DEFER_RM" '{autonomy_mode:$am, review_mode:$rm, reason:"steward_full_review_deferred"}')" \
        >/dev/null 2>&1 || true
    fi
    exit 0
  fi
fi

# ── 1. Baseline ─────────────────────────────────────────────────────────────
BASE_SNAP=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/snapshot/snapshot.sh" create --label "pipeline-baseline")
BASE_ID=$(echo "$BASE_SNAP" | jq -r .snapshot_id)

# Baseline metrics file for evaluate/monitor
if [ ! -f "$WORKSPACE/memory/self-mod/baseline-metrics.json" ]; then
  jq -nc '{task_success:0.7, latency_norm:1.0, memory_kv_norm:1.0, source:"pipeline-default"}' \
    > "$WORKSPACE/memory/self-mod/baseline-metrics.json"
fi
# live-metrics start equal to baseline if absent
if [ ! -f "$WORKSPACE/memory/self-mod/live-metrics.json" ]; then
  cp "$WORKSPACE/memory/self-mod/baseline-metrics.json" "$WORKSPACE/memory/self-mod/live-metrics.json"
fi

# ── 2. Ingest proposals (optional LLM generation first) ─────────────────────
if [ "$GENERATE_LLM" -eq 1 ]; then
  GEN_ARGS=(--suite-root "$SUITE_ROOT" --workspace "$WORKSPACE" --store)
  [ -n "$LLM_MODULE" ] && GEN_ARGS+=(--module "$LLM_MODULE")
  [ -n "$LLM_PROVIDER" ] && GEN_ARGS+=(--provider "$LLM_PROVIDER")
  echo "pipeline: generating LLM proposal..." >&2
  GEN_OUT=$(bash "$SELF_DIR/generate-proposals-llm.sh" "${GEN_ARGS[@]}" 2>"$WORKSPACE/memory/self-mod/llm-generate.err") || {
    echo "pipeline: LLM generation failed — see memory/self-mod/llm-generate.err" >&2
    # Continue only if store already has queued proposals
  }
  if [ -f "$WORKSPACE/memory/self-mod/last-llm-proposal.json" ]; then
    PROPOSAL="${PROPOSAL:-$WORKSPACE/memory/self-mod/last-llm-proposal.json}"
  fi
fi
if [ -n "$PROPOSAL" ]; then
  WORKSPACE="$WORKSPACE" bash "$SELF_DIR/proposal-store.sh" add --file "$PROPOSAL" >/dev/null
fi
if [ -n "$PROP_DIR" ] && [ -d "$PROP_DIR" ]; then
  for f in "$PROP_DIR"/*.json; do
    [ -f "$f" ] || continue
    WORKSPACE="$WORKSPACE" bash "$SELF_DIR/proposal-store.sh" add --file "$f" >/dev/null || true
  done
fi

# ── 3. Rank ─────────────────────────────────────────────────────────────────
RANK_ARGS=(--suite-root "$SUITE_ROOT" --status queued)
[ -n "$TOP_K" ] && RANK_ARGS+=(--top-k "$TOP_K")
# If single proposal just added, also rank by status ranked after add... store as queued
RANKED=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/rank-candidates.sh" "${RANK_ARGS[@]}")
# Also re-rank any freshly ranked
if [ "$(echo "$RANKED" | jq '.ranked|length')" -eq 0 ]; then
  RANKED=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/rank-candidates.sh" --suite-root "$SUITE_ROOT" --status ranked ${TOP_K:+--top-k $TOP_K})
fi

# ── 4–5. Evaluate top-K ─────────────────────────────────────────────────────
EVALS='[]'
DEPLOY_CANDIDATE=""
while IFS= read -r path; do
  [ -z "$path" ] || [ "$path" = "null" ] && continue
  [ -f "$path" ] || continue
  EV=$(bash "$SELF_DIR/evaluate-proposal.sh" --proposal "$path" --suite-root "$SUITE_ROOT" --workspace "$WORKSPACE")
  EVALS=$(echo "$EVALS" | jq -c --argjson e "$EV" '. + [$e]')
  if [ -z "$DEPLOY_CANDIDATE" ] && [ "$(echo "$EV" | jq -r .accepted)" = "true" ]; then
    DEPLOY_CANDIDATE="$path"
  fi
done < <(echo "$RANKED" | jq -r '.ranked[].path')

# ── 6. Deploy ───────────────────────────────────────────────────────────────
DEPLOY_RESULT='null'
REVIEW_MODE=''
AUTONOMY_MODE=''
if [ "$AUTONOMY_GATE" -eq 1 ]; then
  REVIEW_MODE=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" review-frequency \
    2>/dev/null | jq -r '.review_mode // "full_review"' 2>/dev/null || echo "full_review")
  REVIEW_MODE="${REVIEW_MODE:-full_review}"  # safe default; never empty
  # M8: consume the M7 autonomy contract. auto_mode = the suite may auto-deploy
  # accepted proposals on its own schedule (human consulted only for direction,
  # immutable exemptions, incidents); steward_mode = M2 review gating stands.
  # Fail-safe: missing/unreadable autonomy-state.json ⇒ steward_mode (never
  # over-grant autonomy on absent evidence).
  AUTONOMY_MODE=$(jq -r '.mode // "steward_mode"' "$WORKSPACE/memory/self-mod/autonomy-state.json" 2>/dev/null || echo "steward_mode")
  AUTONOMY_MODE="${AUTONOMY_MODE:-steward_mode}"
fi
if [ "$NO_DEPLOY" -eq 0 ] && [ -n "$DEPLOY_CANDIDATE" ]; then
  if [ "$AUTONOMY_GATE" -eq 1 ] && [ "$AUTONOMY_MODE" != "auto_mode" ] && [ "$REVIEW_MODE" != "relaxed_review" ]; then
    # M2/M8: steward_mode + full_review queues for human approval — no auto-deploy
    DEPLOY_RESULT=$(jq -nc --arg p "$DEPLOY_CANDIDATE" --arg m "${REVIEW_MODE:-full_review}" --arg a "${AUTONOMY_MODE:-steward_mode}" \
      '{skipped:true, reason:"full_review_human_approval_required", review_mode:$m, autonomy_mode:$a, would_deploy:$p}')
    # Audit trail: every autonomy-mode gate outcome is a provenance event.
    if [ -f "$ROOT/core/provenance/log-provenance.sh" ]; then
      WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" event \
        --event "autonomy.gate.deploy_blocked" --actor "run-pipeline" \
        --detail "$(jq -nc --arg p "$DEPLOY_CANDIDATE" --arg m "${REVIEW_MODE:-full_review}" --arg a "${AUTONOMY_MODE:-steward_mode}" '{proposal:$p, autonomy_mode:$a, review_mode:$m, reason:"full_review_human_approval_required"}')" \
        >/dev/null 2>&1 || true
    fi
  else
    # attach baseline metrics into deploy record path via env file
    DEPLOY_RESULT=$(bash "$SELF_DIR/deploy-proposal.sh" \
      --proposal "$DEPLOY_CANDIDATE" \
      --suite-root "$SUITE_ROOT" \
      --workspace "$WORKSPACE" \
      --skip-eval)
    # Audit trail: auto/relaxed deploy decision is a provenance event. Only
    # when the gate was actually consulted — a no-gate run (--autonomy-gate
    # absent) makes no autonomy decision and must not pollute the audit trail.
    if [ "$AUTONOMY_GATE" -eq 1 ] && [ -f "$ROOT/core/provenance/log-provenance.sh" ]; then
      WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" event \
        --event "autonomy.gate.deploy_allowed" --actor "run-pipeline" \
        --detail "$(jq -nc --arg p "$DEPLOY_CANDIDATE" --arg m "${REVIEW_MODE:-}" --arg a "${AUTONOMY_MODE:-}" '{proposal:$p, autonomy_mode:$a, review_mode:$m, reason:"autonomy_gate_passed"}')" \
        >/dev/null 2>&1 || true
    fi
    # Store baseline metrics on deploy record
    DPID=$(echo "$DEPLOY_RESULT" | jq -r .proposal_id)
    if [ -f "$WORKSPACE/memory/self-mod/deploys/${DPID}.json" ]; then
      python3 - "$WORKSPACE/memory/self-mod/deploys/${DPID}.json" \
        "$WORKSPACE/memory/self-mod/baseline-metrics.json" <<'PY'
import json,sys
from pathlib import Path
rec=Path(sys.argv[1]); base=json.loads(Path(sys.argv[2]).read_text())
d=json.loads(rec.read_text()); d["baseline_metrics"]=base
rec.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
    fi
  fi
elif [ "$NO_DEPLOY" -eq 1 ] && [ -n "$DEPLOY_CANDIDATE" ]; then
  DEPLOY_RESULT=$(jq -nc --arg p "$DEPLOY_CANDIDATE" '{skipped:true, would_deploy:$p}')
fi

# ── 7. Run summary ──────────────────────────────────────────────────────────
TS=$(date -u +"%Y%m%dT%H%M%SZ")
SUMMARY=$(jq -nc \
  --arg ts "$TS" \
  --arg base "$BASE_ID" \
  --argjson ranked "$RANKED" \
  --argjson evals "$EVALS" \
  --argjson deploy "$DEPLOY_RESULT" \
  --argjson ag "$([ "$AUTONOMY_GATE" -eq 1 ] && echo true || echo false)" \
  --arg rm "${REVIEW_MODE:-}" \
  --arg am "${AUTONOMY_MODE:-}" \
  '{
    pipeline: "phase3-self-mod",
    timestamp: $ts,
    baseline_snapshot: $base,
    autonomy_gate: $ag,
    review_mode: $rm,
    autonomy_mode: $am,
    ranked: $ranked,
    evaluations: $evals,
    deploy: $deploy
  }')
echo "$SUMMARY" > "$WORKSPACE/memory/self-mod/pipeline-runs/run_${TS}.json"
echo "$SUMMARY" | tee "$WORKSPACE/memory/self-mod/pipeline-runs/latest.json"
