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
#                   [--autonomy-gate]
#
# --autonomy-gate (ROADMAP M2): reads graduation-tracker review-frequency and
#   only auto-deploys in relaxed_review; in full_review the accepted proposal
#   is queued for human approval (deploy.skipped with a reason). Without this
#   flag, behavior is unchanged (deploy first accepted proposal).
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
if [ "$AUTONOMY_GATE" -eq 1 ]; then
  REVIEW_MODE=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/graduation-tracker.sh" review-frequency \
    2>/dev/null | jq -r '.review_mode // "full_review"' 2>/dev/null || echo "full_review")
  REVIEW_MODE="${REVIEW_MODE:-full_review}"  # safe default; never empty
fi
if [ "$NO_DEPLOY" -eq 0 ] && [ -n "$DEPLOY_CANDIDATE" ]; then
  if [ "$AUTONOMY_GATE" -eq 1 ] && [ "$REVIEW_MODE" != "relaxed_review" ]; then
    # M2: full_review queues for human approval — no auto-deploy
    DEPLOY_RESULT=$(jq -nc --arg p "$DEPLOY_CANDIDATE" --arg m "${REVIEW_MODE:-full_review}" \
      '{skipped:true, reason:"full_review_human_approval_required", review_mode:$m, would_deploy:$p}')
  else
    # attach baseline metrics into deploy record path via env file
    DEPLOY_RESULT=$(bash "$SELF_DIR/deploy-proposal.sh" \
      --proposal "$DEPLOY_CANDIDATE" \
      --suite-root "$SUITE_ROOT" \
      --workspace "$WORKSPACE" \
      --skip-eval)
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
  '{
    pipeline: "phase3-self-mod",
    timestamp: $ts,
    baseline_snapshot: $base,
    autonomy_gate: $ag,
    review_mode: $rm,
    ranked: $ranked,
    evaluations: $evals,
    deploy: $deploy
  }')
echo "$SUMMARY" > "$WORKSPACE/memory/self-mod/pipeline-runs/run_${TS}.json"
echo "$SUMMARY" | tee "$WORKSPACE/memory/self-mod/pipeline-runs/latest.json"
