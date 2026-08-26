#!/bin/bash
# check-tier.sh — Phase 5: evaluate current autonomy tier against graduation criteria.
#
# Reads the live graduation state and determines whether the system qualifies
# for tier promotion or should be demoted.  This is the machine-readable
# enforcement of the trust ladder defined in autonomy-tiers.json.
#
# Usage:
#   check-tier.sh [--workspace PATH]
#
# Output: JSON with current tier, eligibility for next tier, and reasons.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
TIERS_FILE="$SELF_DIR/autonomy-tiers.json"
STATE_FILE="$WORKSPACE/memory/self-mod/autonomy-tiers-state.json"
GRAD_FILE="$WORKSPACE/memory/self-mod/graduation-streak.json"
AUTO_STATE="$WORKSPACE/memory/self-mod/autonomy-state.json"

PROMOTE=0
DEMOTE=0
REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; STATE_FILE="$WORKSPACE/memory/self-mod/autonomy-tiers-state.json"; GRAD_FILE="$WORKSPACE/memory/self-mod/graduation-streak.json"; AUTO_STATE="$WORKSPACE/memory/self-mod/autonomy-state.json"; shift 2 ;;
    --promote) PROMOTE=1; shift ;;
    --demote) DEMOTE=1; shift ;;
    --reason) REASON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Initialize tier state if missing
if [ ! -f "$STATE_FILE" ]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -nc '{
    current_tier: 0,
    tier_achieved_at: null,
    consecutive_clean: 0,
    rollbacks_in_window: 0,
    last_rollback_at: null,
    verification_pass_rate: 0.0,
    daemon_healthy_days: 0,
    graduation_evaluated_at: null
  }' > "$STATE_FILE"
fi

python3 - "$TIERS_FILE" "$STATE_FILE" "$GRAD_FILE" "$AUTO_STATE" <<'PYEOF'
import json, sys
from pathlib import Path

tiers_file = Path(sys.argv[1])
state_file = Path(sys.argv[2])
grad_file = Path(sys.argv[3])
auto_file = Path(sys.argv[4])

tiers = json.loads(tiers_file.read_text())["tiers"]
state = json.loads(state_file.read_text()) if state_file.exists() else {
    "current_tier": 0, "consecutive_clean": 0, "rollbacks_in_window": 0,
    "verification_pass_rate": 0.0, "daemon_healthy_days": 0
}

# Enrich state from graduation-tracker
grad = {}
if grad_file.exists():
    try:
        grad = json.loads(grad_file.read_text())
    except Exception:
        pass
state["consecutive_clean"] = max(state.get("consecutive_clean", 0), grad.get("clean_streak", 0))

# Enrich from autonomy-state
auto = {}
if auto_file.exists():
    try:
        auto = json.loads(auto_file.read_text())
    except Exception:
        pass

current_tier = state.get("current_tier", 0)
current_tier_str = str(current_tier)

def check_criteria(state, criteria):
    """Check if state meets graduation criteria. Returns (met, reasons)."""
    reasons = []
    met = True

    if "consecutive_clean_proposals" in criteria:
        required = criteria["consecutive_clean_proposals"]
        actual = state.get("consecutive_clean", 0)
        if actual < required:
            met = False
            reasons.append(f"consecutive_clean: {actual}/{required}")

    if "zero_rollbacks_in_days" in criteria:
        # Simplified: check rollbacks_in_window
        max_rollbacks = criteria.get("auto_rollbacks_in_window", 0)
        actual = state.get("rollbacks_in_window", 0)
        if actual > max_rollbacks:
            met = False
            reasons.append(f"rollbacks_in_window: {actual}/{max_rollbacks}")

    if "verification_sweep_pass_rate" in criteria:
        required = criteria["verification_sweep_pass_rate"]
        actual = state.get("verification_pass_rate", 0.0)
        if actual < required:
            met = False
            reasons.append(f"verification_pass_rate: {actual:.2f}/{required:.2f}")

    if "daemon_healthy_days" in criteria:
        required = criteria["daemon_healthy_days"]
        actual = state.get("daemon_healthy_days", 0)
        if actual < required:
            met = False
            reasons.append(f"daemon_healthy_days: {actual}/{required}")

    if "unhealthy_jobs_max" in criteria:
        required = criteria["unhealthy_jobs_max"]
        unhealthy = auto.get("evidence", {}).get("unhealthy_jobs", 0)
        if unhealthy > required:
            met = False
            reasons.append(f"unhealthy_jobs: {unhealthy}/{required}")

    return met, reasons

# Check eligibility for next tier
next_tier = str(current_tier + 1)
promotion_eligible = False
promotion_reasons = []

if next_tier in tiers:
    criteria = tiers[next_tier]["graduation_criteria"]
    promotion_eligible, promotion_reasons = check_criteria(state, criteria)

# Check if current tier should be demoted (criteria no longer met)
demotion_needed = False
demotion_reasons = []
if current_tier_str in tiers:
    # Current tier's requirements are the previous tier's graduation criteria
    prev_tier = str(current_tier - 1)
    if prev_tier in tiers:
        prev_criteria = tiers[prev_tier]["graduation_criteria"]
        # For demotion, check the minimum bar (not graduation, but maintenance)
        maintenance = {
            "consecutive_clean_proposals": max(1, prev_criteria.get("consecutive_clean_proposals", 1) // 2),
            "verification_sweep_pass_rate": prev_criteria.get("verification_sweep_pass_rate", 0.5) * 0.9,
        }
        demotion_needed, demotion_reasons = check_criteria(state, maintenance)

result = {
    "current_tier": current_tier,
    "current_tier_name": tiers.get(current_tier_str, {}).get("name", "unknown"),
    "next_tier": int(next_tier) if next_tier in tiers else None,
    "next_tier_name": tiers.get(next_tier, {}).get("name"),
    "promotion_eligible": promotion_eligible,
    "promotion_reasons": promotion_reasons,
    "demotion_needed": demotion_needed,
    "demotion_reasons": demotion_reasons,
    "state": {
        "consecutive_clean": state.get("consecutive_clean", 0),
        "rollbacks_in_window": state.get("rollbacks_in_window", 0),
        "verification_pass_rate": state.get("verification_pass_rate", 0.0),
        "daemon_healthy_days": state.get("daemon_healthy_days", 0)
    },
    "allowed_actions": tiers.get(current_tier_str, {}).get("allowed_actions", []),
    "blocked_actions": tiers.get(current_tier_str, {}).get("blocked_actions", [])
}

print(json.dumps(result, indent=2))
PYEOF

# ── Tier change audit trail ────────────────────────────────────────────────
# When --promote or --demote is passed, update the tier state and write a
# provenance event so the live tier history becomes an auditable record.
PROVENANCE_SH="$SELF_DIR/../provenance/log-provenance.sh"
if [ "$PROMOTE" -eq 1 ] || [ "$DEMOTE" -eq 1 ]; then
  CURRENT=$(jq -r '.current_tier' "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$PROMOTE" -eq 1 ]; then
    NEW_TIER=$((CURRENT + 1))
    ACTION="promote"
  else
    NEW_TIER=$((CURRENT - 1))
    [ "$NEW_TIER" -lt 0 ] && NEW_TIER=0
    ACTION="demote"
  fi

  # Validate new tier exists in autonomy-tiers.json
  TIER_NAME=$(jq -r ".tiers[\"$NEW_TIER\"].name // empty" "$TIERS_FILE" 2>/dev/null)
  if [ -z "$TIER_NAME" ]; then
    echo "check-tier: cannot $ACTION to tier $NEW_TIER — not defined in autonomy-tiers.json" >&2
    exit 1
  fi

  # Update state file
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --argjson tier "$NEW_TIER" --arg ts "$NOW" \
    '.current_tier = $tier | .tier_achieved_at = $ts | .graduation_evaluated_at = $ts' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

  # Write provenance event if log-provenance.sh is available
  if [ -x "$PROVENANCE_SH" ]; then
    NOTE="Tier $CURRENT ($ACTION to $NEW_TIER): ${REASON:-no reason specified}"
    WORKSPACE="$WORKSPACE" bash "$PROVENANCE_SH" \
      --event "autonomy.tier.$ACTION" \
      --detail "$NOTE" \
      --source "check-tier.sh" \
      2>/dev/null || true
  fi

  echo "Tier $ACTION: $CURRENT → $NEW_TIER ($TIER_NAME)"
fi
