#!/bin/bash
# attention-filter.sh — Compute the five-dimensional attention relevance score
# for a single signal. Sources scoring logic from gate.sh for consistency —
# this is the standalone, single-signal interface to the same algorithm.
#
# Usage:
#   echo '{"source":"amygdala-memory","signal":"positive_state",...}' | attention-filter.sh
#
# Output: JSON with the scored dimensions and final gate score.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"

# The scoring semantics mirror gate.sh's _score_signal() (the canonical
# implementation) — re-implemented here to keep this script standalone
# while maintaining identical semantics to gate.sh)
PFC_STATE="$WORKSPACE/memory/pfc-state.json"
EXEC_LOAD="$WORKSPACE/memory/executive-load.json"
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"

raw=$(cat)
source=$(echo "$raw" | jq -r '.source // ""' 2>/dev/null)
signal_name=$(echo "$raw" | jq -r '.signal // ""' 2>/dev/null)
intensity=$(echo "$raw" | jq -r '.intensity // "0.5"' 2>/dev/null)

# ── Helper: compute simple word overlap with active goals ─────────────
goal_relevance=0.0
if [[ -f "$PFC_STATE" ]]; then
    goals_json=$(jq -r '[.goals[]? | select(.status == "active") | .description] | join(" ")' "$PFC_STATE" 2>/dev/null || echo "")
    if [[ -n "$goals_json" ]]; then
        combined="$source $signal_name"
        overlap=0
        for word in $goals_json; do
            # Literal substring match (quoted RHS), not regex — same fix as
            # gate.sh's _score_signal: goal words with regex metacharacters
            # must match literally.
            [[ "$combined" == *"$word"* ]] && overlap=$((overlap + 1))
        done
        goal_relevance=$(echo "scale=4; if ($overlap > 0) $(echo "scale=4; if ($overlap * 0.15 > 1.0) 1.0 else $overlap * 0.15" | bc) else 0" | bc 2>/dev/null || echo "0")
    fi
fi

# ── Novelty: higher for less-recently-seen signals ─────────────────────
# Mirrors gate.sh::_score_signal: checks suppressedQueue history
novelty=0.7
if [[ -f "$STATE_FILE" ]]; then
    recent_count=$(jq --arg src "$source" --arg sig "$signal_name" \
        '[.suppressedQueue[]? | select(.signal.source == $src and .signal.signal == $sig)] | length' \
        "$STATE_FILE" 2>/dev/null || echo "0")
    # Less suppressed = more novel
    if [[ "$recent_count" -gt 5 ]]; then novelty=0.1
    elif [[ "$recent_count" -gt 2 ]]; then novelty=0.3
    elif [[ "$recent_count" -gt 0 ]]; then novelty=0.5
    fi
fi

# ── Urgency: intensity × source priority ───────────────────────────────
case "$source" in
    acc-error-memory|anterior-cingulate-memory) src_pri=0.9 ;;
    amygdala-memory|heartbeat-memory) src_pri=0.7 ;;
    prefrontal-cortex-memory) src_pri=0.8 ;;
    vta-memory) src_pri=0.6 ;;
    *) src_pri=0.5 ;;
esac
urgency=$(echo "scale=4; $intensity * $src_pri" | bc 2>/dev/null || echo "0.5")

# ── Load headroom ──────────────────────────────────────────────────────
exec_load=0.5
if [[ -f "$EXEC_LOAD" ]]; then
    exec_load=$(jq -r '.E // 0.5' "$EXEC_LOAD" 2>/dev/null || echo "0.5")
fi
headroom=$(echo "scale=4; 1.0 - $exec_load" | bc 2>/dev/null || echo "0.5")
if (( $(echo "$headroom < 0" | bc -l 2>/dev/null) )); then headroom=0.0; fi

# ── Circadian gain ─────────────────────────────────────────────────────
hour=$(date -u +%H); hour=$((10#$hour))
if [[ $hour -ge 8 && $hour -lt 20 ]]; then circadian=1.5
elif [[ $hour -ge 6 && $hour -lt 8 ]] || [[ $hour -ge 20 && $hour -lt 22 ]]; then circadian=1.0
else circadian=0.5
fi

# ── Final score ────────────────────────────────────────────────────────
score=$(echo "scale=6; ($goal_relevance * 0.35 + $novelty * 0.15 + $urgency * 0.25 + $headroom * 0.25) * $circadian" | bc 2>/dev/null || echo "0.3")

# ── Action ─────────────────────────────────────────────────────────────
if (( $(echo "$score >= 0.70" | bc -l 2>/dev/null) )); then action="amplify"
elif (( $(echo "$score >= 0.40" | bc -l 2>/dev/null) )); then action="pass"
elif (( $(echo "$score >= 0.20" | bc -l 2>/dev/null) )); then action="attenuate"
else action="suppress"
fi

jq -nc \
    --arg source "$source" \
    --arg signal "$signal_name" \
    --argjson intensity "$intensity" \
    --argjson score "$score" \
    --arg action "$action" \
    --argjson goalRelevance "$goal_relevance" \
    --argjson novelty "$novelty" \
    --argjson urgency "$urgency" \
    --argjson headroom "$headroom" \
    --argjson circadian "$circadian" \
'{
    source: $source,
    signal: $signal,
    intensity: $intensity,
    gateScore: $score,
    action: $action,
    dimensions: {
        goalRelevance: $goalRelevance,
        noveltyBonus: $novelty,
        urgency: $urgency,
        loadHeadroom: $headroom,
        circadianGain: $circadian
    }
}'
