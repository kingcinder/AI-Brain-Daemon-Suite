#!/bin/bash
# monitor.sh — Post-deploy continuous check; auto-rollback on threshold breach.
#
# Reads active deploys under memory/self-mod/deploys/*.json (rolled_back=false).
# Compares current metrics to deploy-time baseline; on breach, calls rollback.sh.
#
# Usage:
#   monitor.sh [--workspace PATH] [--suite-root PATH] [--dry-run]
#
# Metrics sources (best-effort):
#   memory/self-mod/live-metrics.json  {task_success, latency_norm, memory_kv_norm}
#   memory/executive-load.json         (informational)
# If live-metrics missing, monitor is a no-op success (no false rollbacks).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
DRY=0
THRESH="$SELF_DIR/thresholds.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

DEPLOY_DIR="$WORKSPACE/memory/self-mod/deploys"
LIVE="$WORKSPACE/memory/self-mod/live-metrics.json"
mkdir -p "$DEPLOY_DIR"

if [ ! -f "$LIVE" ]; then
  jq -nc '{checked:0, rolled_back:[], skipped:"no_live_metrics"}'
  exit 0
fi

ACTIONS='[]'
CHECKED=0

for rec in "$DEPLOY_DIR"/*.json; do
  [ -f "$rec" ] || continue
  [ "$(basename "$rec")" = "LATEST" ] && continue
  RB=$(jq -r '.rolled_back // false' "$rec")
  [ "$RB" = "true" ] && continue
  MON=$(jq -r '.monitor.status // "active"' "$rec")
  [ "$MON" = "active" ] || continue

  CHECKED=$((CHECKED + 1))
  PID=$(jq -r .proposal_id "$rec")

  BREACH=$(python3 - "$THRESH" "$LIVE" "$rec" <<'PY'
import json,sys
th=json.loads(open(sys.argv[1]).read())["rollback"]
live=json.loads(open(sys.argv[2]).read())
rec=json.loads(open(sys.argv[3]).read())
base=rec.get("baseline_metrics") or rec.get("metrics_at_deploy") or {
  "task_success": 1.0,
  "latency_norm": live.get("latency_norm", 1.0),
  "memory_kv_norm": live.get("memory_kv_norm", 1.0),
}
# Prefer explicit baseline stored at deploy
if "baseline_metrics" in rec:
    base = rec["baseline_metrics"]
ts_b=float(base.get("task_success", 1.0))
lat_b=float(base.get("latency_norm", 1.0)) or 1.0
mem_b=float(base.get("memory_kv_norm", 1.0)) or 1.0
ts=float(live.get("task_success", ts_b))
lat=float(live.get("latency_norm", lat_b))
mem=float(live.get("memory_kv_norm", mem_b))
breaches=[]
if (ts_b - ts) > th["task_success_decrease_max"]:
    breaches.append("task_success_decrease")
if lat_b > 0 and (lat/lat_b - 1.0) > th["latency_increase_max"]:
    breaches.append("latency_increase")
if mem_b > 0 and (mem/mem_b - 1.0) > th["memory_kv_increase_max"]:
    breaches.append("memory_kv_increase")
if live.get("regression_failed") is True and th.get("any_regression_failure"):
    breaches.append("regression_failure")
print(json.dumps({"proposal_id": rec.get("proposal_id"), "breaches": breaches, "rollback": len(breaches)>0}))
PY
)

  if [ "$(echo "$BREACH" | jq -r .rollback)" = "true" ]; then
    if [ "$DRY" -eq 1 ]; then
      ACTIONS=$(echo "$ACTIONS" | jq -c --argjson b "$BREACH" '. + [$b + {action:"would_rollback"}]')
    else
      bash "$SELF_DIR/rollback.sh" --deploy-record "$rec" --suite-root "$SUITE_ROOT" \
        --workspace "$WORKSPACE" --reason "monitor:$(echo "$BREACH" | jq -r '.breaches|join(",")')" \
        >/dev/null
      ACTIONS=$(echo "$ACTIONS" | jq -c --argjson b "$BREACH" '. + [$b + {action:"rolled_back"}]')
    fi
  fi
done

jq -nc --argjson n "$CHECKED" --argjson a "$ACTIONS" '{checked:$n, actions:$a}'
