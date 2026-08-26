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
  # Reject illegal targets before ranking expense — mktemp file (never a
  # predictable /tmp/name.$$ path)
  CK_FILE=$(mktemp "${TMPDIR:-/tmp}/aibrain-rank-check.XXXXXX")
  if ! bash "$CHECK" --suite-root "$SUITE_ROOT" --proposal "$f" >"$CK_FILE" 2>/dev/null; then
    # mark rejected in store if managed
    pid=$(jq -r .proposal_id "$f")
    if [ -f "$WORKSPACE/memory/self-mod/proposals/${pid}.json" ]; then
      WORKSPACE="$WORKSPACE" bash "$STORE_SH" set-status --id "$pid" --status rejected >/dev/null || true
      # annotate reason
      python3 - "$f" "$CK_FILE" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); c=json.loads(Path(sys.argv[2]).read_text())
d=json.loads(p.read_text()); d["status"]="rejected"; d["reject_reason"]=c.get("rejected")
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
    fi
    rm -f "$CK_FILE"
    continue
  fi
  rm -f "$CK_FILE"

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

  # Phase 3: verification-history boost — proposals targeting modules with
  # recent verification failures get a ranking boost (the suite should fix
  # what it has already measured as broken, not just what is convenient).
  TARGET_MOD=$(jq -r '.module // empty' "$f")
  VERIFY_BOOST=0
  if [ -n "$TARGET_MOD" ] && [ -f "$WORKSPACE/memory/verification-sweep.json" ]; then
    VERIFY_BOOST=$(python3 - "$TARGET_MOD" "$WORKSPACE/memory/verification-sweep.json" <<'PYV'
import json, sys
mod = sys.argv[1]
try:
    data = json.loads(open(sys.argv[2]).read())
except Exception:
    print(0); sys.exit(0)
failures = data.get("failures", [])
# Boost proportional to number of failures for this module (max +0.15)
matches = sum(1 for f in failures if f.get("module") == mod or mod in f.get("test", ""))
print(min(0.15, matches * 0.05))
PYV
  )
  fi

  # Phase 3: ACC error-lesson boost — proposals whose description mentions
  # a known error pattern get a small boost (the suite should learn from
  # its own confirmed error history).
  ACC_BOOST=0
  if [ -f "$WORKSPACE/memory/acc-lessons.json" ]; then
    DESC=$(jq -r '.description // empty' "$f")
    if [ -n "$DESC" ]; then
      ACC_BOOST=$(python3 - "$DESC" "$WORKSPACE/memory/acc-lessons.json" <<'PYA'
import json, sys, re
desc = sys.argv[1].lower()
try:
    lessons = json.loads(open(sys.argv[2]).read())
except Exception:
    print(0); sys.exit(0)
patterns = [l.get("name", "").lower() for l in lessons if isinstance(l, dict)]
matches = sum(1 for p in patterns if p and re.search(re.escape(p[:8]), desc))
print(min(0.10, matches * 0.03))
PYA
    )
    fi
  fi

  # Phase 3: cerebellum calibration signal — proposals targeting modules with
  # low calibration get a small boost (prioritize fixing imprecise modules).
  CAL_BOOST=0
  if [ -n "$TARGET_MOD" ] && [ -f "$WORKSPACE/memory/cerebellum-state.json" ]; then
    CAL_BOOST=$(python3 - "$TARGET_MOD" "$WORKSPACE/memory/cerebellum-state.json" <<'PYC'
import json, sys
mod = sys.argv[1]
try:
    data = json.loads(open(sys.argv[2]).read())
except Exception:
    print(0); sys.exit(0)
per_skill = data.get("per_skill", {})
prec = per_skill.get(mod, {}).get("precision", 0.5)
# Low precision (< 0.3) → small boost to fix imprecise modules
print(0.08 if prec < 0.3 else (0.04 if prec < 0.5 else 0))
PYC
  )
  fi

  # Apply boosts to U (clamped at 1.0)
  BOOST=$(python3 -c "print(min(1.0, float('$U') + $VERIFY_BOOST + $ACC_BOOST + $CAL_BOOST))")
  U="$BOOST"

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
