#!/bin/bash
# arbitrate-proposals.sh — Phase 4: Executive-level proposal arbitration.
#
# Scores self-modification proposals against active PFC goals and current
# priorities, so two simultaneously-plausible modifications are ranked by
# goal alignment rather than applied in arrival order.  This is the
# goal/self-mod-proposal equivalent of basal-ganglia action-select.sh
# (which handles action-level competition).
#
# Usage:
#   arbitrate-proposals.sh [--workspace PATH] [--suite-root PATH]
#     [--proposals-dir DIR] [--top-k N]
#
# Env: WORKSPACE
# Output: JSON array of proposals ranked by goal-aligned utility.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
PROP_DIR="$WORKSPACE/memory/self-mod/proposals"
TOP_K=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --suite-root) shift 2 ;;  # accepted for CLI compat; suite root is derived from SELF_DIR
    --proposals-dir) PROP_DIR="$2"; shift 2 ;;
    --top-k) TOP_K="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Load active PFC goals ──────────────────────────────────────────────────
PFC_STATE="$WORKSPACE/memory/pfc-state.json"
GOALS="[]"
if [ -f "$PFC_STATE" ]; then
  GOALS=$(jq -c '[.goals[]? | select(.status == "active") | {description, priority}]' "$PFC_STATE" 2>/dev/null || echo "[]")
fi

# ── Load neuromod state (DA for goal-weight, cortisol for stress bias) ──────
NEUROMOD="$WORKSPACE/memory/neuromod-state.json"
DA=0.5
CORTISOL=0.3
if [ -f "$NEUROMOD" ]; then
  DA=$(jq -r '.modulators.dopamine.value // 0.5' "$NEUROMOD" 2>/dev/null || echo 0.5)
  CORTISOL=$(jq -r '.modulators.cortisol.value // 0.3' "$NEUROMOD" 2>/dev/null || echo 0.3)
fi

# ── Collect ranked proposals ────────────────────────────────────────────────
# Prefer already-ranked proposals (from rank-candidates.sh), fall back to queued
if [ -z "$TOP_K" ]; then
  TOP_K=$(jq -r '.arbitration.top_k // 3' "$ROOT/core/self-mod/thresholds.json" 2>/dev/null || echo 3)
fi

mapfile -t PROP_FILES < <(
  # First try ranked proposals
  for f in "$PROP_DIR"/*.json; do
    [ -f "$f" ] || continue
    STATUS=$(jq -r '.status // empty' "$f" 2>/dev/null || echo "")
    [ "$STATUS" = "ranked" ] && echo "$f"
  done
  # Fall back to queued
  for f in "$PROP_DIR"/*.json; do
    [ -f "$f" ] || continue
    STATUS=$(jq -r '.status // empty' "$f" 2>/dev/null || echo "")
    [ "$STATUS" = "queued" ] && echo "$f"
  done
)

if [ ${#PROP_FILES[@]} -eq 0 ]; then
  echo '{"arbitration": "no proposals to arbitrate", "count": 0, "ranked": []}'
  exit 0
fi

# ── Score each proposal against goals ───────────────────────────────────────
RESULT=$(python3 - "$GOALS" "$DA" "$CORTISOL" "$TOP_K" "${PROP_FILES[@]}" <<'PYEOF'
import json, sys, re
from pathlib import Path

goals_json = json.loads(sys.argv[1]) if sys.argv[1] != "[]" else []
da = float(sys.argv[2])
cortisol = float(sys.argv[3])
top_k = int(sys.argv[4])
prop_files = sys.argv[5:]

def goal_alignment_score(description, module, goals):
    """Score how well a proposal aligns with active goals (0.0-1.0)."""
    if not goals:
        return 0.5  # neutral when no goals active
    desc_lower = (description or "").lower()
    mod_lower = (module or "").lower()
    max_align = 0.0
    for g in goals:
        gtext = (g.get("description", "") or "").lower()
        gpriority = float(g.get("priority", 0.5) or 0.5)
        # Keyword overlap between proposal description and goal
        words_desc = set(re.findall(r'\w+', desc_lower))
        words_goal = set(re.findall(r'\w+', gtext))
        if not words_goal:
            continue
        overlap = len(words_desc & words_goal) / max(len(words_goal), 1)
        align = overlap * gpriority
        max_align = max(max_align, align)
    return min(1.0, max_align)

ranked = []
for fp in prop_files:
    try:
        p = json.loads(Path(fp).read_text())
    except Exception:
        continue
    pid = p.get("proposal_id", "unknown")
    desc = p.get("description", "")
    module = p.get("module", "")
    # Base utility from pre-ranking scores
    scores = p.get("scores", {})
    base_u = float(scores.get("pre_utility", 0.5) or 0.5)
    # Goal alignment
    ga = goal_alignment_score(desc, module, goals_json)
    # DA amplifies goal-aligned proposals (dopamine = goal motivation)
    # Cortisol dampens uncertain/risky proposals under stress
    error_rate = float((p.get("estimated_components") or {}).get("error_rate", 0.15) or 0.15)
    stress_penalty = cortisol * error_rate * 0.3  # high cortisol + high risk = bigger penalty
    da_boost = (da - 0.5) * ga * 0.2  # DA above baseline amplifies aligned proposals
    final_u = max(0, min(1.0, base_u + ga * 0.2 + da_boost - stress_penalty))
    ranked.append({
        "proposal_id": pid,
        "module": module,
        "description": desc[:80],
        "pre_utility": base_u,
        "goal_alignment": round(ga, 3),
        "da_boost": round(da_boost, 3),
        "stress_penalty": round(stress_penalty, 3),
        "final_utility": round(final_u, 3),
        "path": fp
    })

ranked.sort(key=lambda r: r["final_utility"], reverse=True)
output = {
    "arbitration": "goal-aligned ranking",
    "active_goals": len(goals_json),
    "da": da,
    "cortisol": cortisol,
    "count": len(ranked),
    "top_k": top_k,
    "ranked": ranked[:top_k]
}
print(json.dumps(output, indent=2))
PYEOF
)

echo "$RESULT"
