#!/bin/bash
# rank-candidates.sh — Rank proposals by Utility Function *before* sandbox.
#
# Uses estimated components on each proposal (or defaults), scores with
# score-utility.sh, sorts descending by U, emits top-K JSON array.
#
# Usage:
#   rank-candidates.sh [--suite-root PATH] [--status queued] [--top-k N]
#   rank-candidates.sh --files a.json,b.json [--top-k N]
# Env: WORKSPACE

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SUITE_ROOT="$ROOT"
STATUS="queued"
TOP_K=""
FILES_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --top-k) TOP_K="$2"; shift 2 ;;
    --files) FILES_CSV="$2"; shift 2 ;;
    *) shift ;;
  esac
done

THRESH="$SELF_DIR/thresholds.json"
if [ -z "$TOP_K" ]; then
  TOP_K=$(jq -r '.ranking.top_k // 3' "$THRESH" 2>/dev/null || echo 3)
fi
MIN_U=$(jq -r '.ranking.min_pre_utility // -1' "$THRESH" 2>/dev/null || echo -1)

SCORE="$ROOT/core/utility/score-utility.sh"
CHECK="$SELF_DIR/check-target.sh"
STORE_SH="$SELF_DIR/proposal-store.sh"

# Collect proposal JSON paths
mapfile -t PATHS < <(
  if [ -n "$FILES_CSV" ]; then
    IFS=',' read -ra arr <<< "$FILES_CSV"
    for f in "${arr[@]}"; do
      [ -f "$f" ] && echo "$f"
    done
  else
    WORKSPACE="$WORKSPACE" bash "$STORE_SH" list --status "$STATUS" \
      | jq -r '.[].proposal_id' 2>/dev/null \
      | while read -r id; do
          f="$WORKSPACE/memory/self-mod/proposals/${id}.json"
          [ -f "$f" ] && echo "$f"
        done
  fi
)

RANKED_JSON="[]"
for f in "${PATHS[@]:-}"; do
  [ -f "$f" ] || continue
  # Reject illegal targets before ranking expense
  if ! bash "$CHECK" --suite-root "$SUITE_ROOT" --proposal "$f" >/tmp/check_$$.json 2>/dev/null; then
    # mark rejected in store if managed
    pid=$(jq -r .proposal_id "$f")
    if [ -f "$WORKSPACE/memory/self-mod/proposals/${pid}.json" ]; then
      WORKSPACE="$WORKSPACE" bash "$STORE_SH" set-status --id "$pid" --status rejected >/dev/null || true
      # annotate reason
      python3 - "$f" /tmp/check_$$.json <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); c=json.loads(Path(sys.argv[2]).read_text())
d=json.loads(p.read_text()); d["status"]="rejected"; d["reject_reason"]=c.get("rejected")
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
    fi
    rm -f /tmp/check_$$.json
    continue
  fi
  rm -f /tmp/check_$$.json

  # Estimate components
  read -r TS RC ER RP < <(python3 - "$f" <<'PY'
import json,sys
d=json.loads(open(sys.argv[1]).read())
c=d.get("estimated_components") or d.get("components") or {}
def g(k, default):
    v=c.get(k)
    return float(v) if v is not None else default
# Defaults: mildly optimistic pre-rank so ranking differentiates on estimates
print(g("task_success", 0.6), g("resource_cost", 0.25), g("error_rate", 0.15), g("regression_penalty", 0.05))
PY
)

  SCORE_JSON=$(bash "$SCORE" --task-success "$TS" --resource-cost "$RC" --error-rate "$ER" --regression-penalty "$RP")
  U=$(echo "$SCORE_JSON" | jq -r .U)

  # Persist pre scores (silent — stdout must remain JSON-only for the ranker)
  python3 - "$f" "$SCORE_JSON" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); s=json.loads(sys.argv[2])
d=json.loads(p.read_text())
d.setdefault("scores",{})
d["scores"]["pre_utility"]=s.get("U")
d["scores"]["pre_components"]=s.get("components")
d["status"]="ranked"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY

  # Compact score JSON for --argjson
  SCORE_COMPACT=$(echo "$SCORE_JSON" | jq -c .)
  RANKED_JSON=$(echo "$RANKED_JSON" | jq -c \
    --arg id "$(jq -r .proposal_id "$f")" \
    --arg path "$f" \
    --argjson u "$U" \
    --argjson score "$SCORE_COMPACT" \
    '. + [{proposal_id:$id, path:$path, pre_utility:$u, score:$score}]')
done

# Sort and top-k, filter min U
RESULT=$(echo "$RANKED_JSON" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
min_u=float('$MIN_U')
top_k=int('$TOP_K')
rows=[r for r in rows if float(r.get('pre_utility', -999)) >= min_u]
rows.sort(key=lambda r: float(r.get('pre_utility', -999)), reverse=True)
print(json.dumps({'top_k': top_k, 'count': len(rows), 'ranked': rows[:top_k]}, indent=2))
")

echo "$RESULT"
