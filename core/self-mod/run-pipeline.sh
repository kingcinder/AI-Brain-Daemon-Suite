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
# --autonomy-gate (ROADMAP M2 + M8, superseded by M9 on 2026-11-13): reads
#   graduation-tracker review-frequency and the persisted autonomy mode
#   (memory/self-mod/autonomy-state.json, written by deep-brain-kernel.py
#   --autonomy) and records both in the run summary as evidence. Under the
#   M9 contract (Dither's order, 2026-11-13) the approval gate is JUNO:
#   neither the autonomy mode nor the review mode blocks a deploy, and no
#   proposal is ever queued for human approval. An accepted proposal
#   (check-target + evaluate green) is approved by Juno and deploys; the
#   decision is recorded as a provenance event
#   (autonomy.gate.deploy_allowed, approver:"juno"). The verification gates
#   — check-target, evaluate/regression, deploy verification, rollback —
#   are unchanged: they are proof, not permission. Without this flag,
#   behavior is unchanged (deploy first accepted proposal, and no gate
#   provenance event is written).
#
# --defer-gate (weekly cycle): retained for back-compat with the cycle
#   tick's flags. Under M9 it no longer defers anything — the weekly cycle
#   always runs; there is no human approval to wait for.
#
# Does not modify Immutable Core modules. Pipeline code under core/self-mod
# is never a legal proposal target.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
TOP_K=""
PROPOSAL=""
PROP_DIR=""
NO_DEPLOY=0
GENERATE_JUNO=0
AUTONOMY_GATE=0
DEFER_GATE=0
JUNO_MODULE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --top-k) TOP_K="$2"; shift 2 ;;
    --proposal) PROPOSAL="$2"; shift 2 ;;
    --proposals-dir) PROP_DIR="$2"; shift 2 ;;
    --no-deploy) NO_DEPLOY=1; shift ;;
    --dry-run) NO_DEPLOY=1; shift ;;
    --generate-juno) GENERATE_JUNO=1; shift ;;
    --autonomy-gate) AUTONOMY_GATE=1; shift ;;
    --defer-gate) DEFER_GATE=1; shift ;;
    --juno-module) JUNO_MODULE="$2"; shift 2 ;;
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

# ── 0. Defer gate: REMOVED under M9 (2026-11-13) ────────────────────────────
# The weekly cycle formerly deferred the whole run under steward_mode +
# full_review to wait for human approval. The approval gate is Juno now;
# nothing defers to the human, so --defer-gate is accepted and ignored,
# and the run always proceeds to baseline/generate/rank/evaluate/deploy.

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

# ── 2. Ingest proposals (optional Juno generation first) ────────────────────
if [ "$GENERATE_JUNO" -eq 1 ]; then
  GEN_ARGS=(--suite-root "$SUITE_ROOT" --workspace "$WORKSPACE" --store)
  [ -n "$JUNO_MODULE" ] && GEN_ARGS+=(--module "$JUNO_MODULE")
  echo "pipeline: Juno is generating a proposal..." >&2
  if ! bash "$SELF_DIR/generate-proposals-juno.sh" "${GEN_ARGS[@]}" 2>"$WORKSPACE/memory/self-mod/juno-generate.err"; then
    echo "pipeline: Juno generation failed — see memory/self-mod/juno-generate.err" >&2
    # Continue only if store already has queued proposals
  fi
  if [ -f "$WORKSPACE/memory/self-mod/last-juno-proposal.json" ]; then
    PROPOSAL="${PROPOSAL:-$WORKSPACE/memory/self-mod/last-juno-proposal.json}"
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
  # M9: autonomy mode + review mode are recorded as evidence only. They no
  # longer gate the deploy — the approval gate is Juno (see header). A
  # missing/unreadable autonomy-state.json still reports as steward_mode in
  # the summary (a truthful record of the evidence state); it blocks nothing.
  AUTONOMY_MODE=$(jq -r '.mode // "steward_mode"' "$WORKSPACE/memory/self-mod/autonomy-state.json" 2>/dev/null || echo "steward_mode")
  AUTONOMY_MODE="${AUTONOMY_MODE:-steward_mode}"
fi
if [ "$NO_DEPLOY" -eq 0 ] && [ -n "$DEPLOY_CANDIDATE" ]; then
  # M9: Juno is the approval gate. An accepted proposal deploys on her
  # approval — no autonomy mode or review mode can queue it for a human.
  # attach baseline metrics into deploy record path via env file
  DEPLOY_RESULT=$(bash "$SELF_DIR/deploy-proposal.sh" \
    --proposal "$DEPLOY_CANDIDATE" \
    --suite-root "$SUITE_ROOT" \
    --workspace "$WORKSPACE" \
    --skip-eval)
  # Audit trail: Juno's gate decision is a provenance event. Only when the
  # gate was actually consulted — a no-gate run (--autonomy-gate absent)
  # makes no gate decision and must not pollute the audit trail.
  if [ "$AUTONOMY_GATE" -eq 1 ] && [ -f "$ROOT/core/provenance/log-provenance.sh" ]; then
    WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" event \
      --event "autonomy.gate.deploy_allowed" --actor "run-pipeline" \
      --detail "$(jq -nc --arg p "$DEPLOY_CANDIDATE" --arg m "${REVIEW_MODE:-}" --arg a "${AUTONOMY_MODE:-}" '{proposal:$p, autonomy_mode:$a, review_mode:$m, approver:"juno", reason:"juno_approval_gate"}')" \
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
