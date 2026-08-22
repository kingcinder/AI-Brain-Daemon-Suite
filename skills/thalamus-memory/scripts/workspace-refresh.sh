#!/bin/bash
# workspace-refresh.sh — Periodic assembly of the workspace `context` block:
# the current circadian phase, active PFC goals, and a neuromod snapshot.
# Chained from neuromod-update.sh (the neuromod_update job). The context
# block is the "contents of attention made first-class" — what Task 4
# injects into arbitration.
#
# Fail-open: a missing neuromod vector yields a neutral snapshot; a missing
# pfc-state leaves goals empty. Never exits non-zero on absent state.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEM="$WORKSPACE/memory"
WS="$MEM/workspace.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$MEM"
exec 200>"$WS.lock"
flock 200

if [[ ! -f "$WS" ]]; then
    cat > "$WS" << 'EOF'
{"version": 1, "lastBroadcastAt": "", "currentFocus": null,
 "recentBroadcasts": [], "attentionFocus": [], "context": {}}
EOF
fi

# ── circadian phase (same logic as heartbeat beat.sh) ──────────────────
HOUR=$(date -u +%H | sed 's/^0//'); [ -z "$HOUR" ] && HOUR=0
WAKE_HOUR=$(jq -r '.circadian.wakeHour // 8' "$MEM/heartbeat-state.json" 2>/dev/null || echo 8)
SLEEP_HOUR=$(jq -r '.circadian.sleepHour // 22' "$MEM/heartbeat-state.json" 2>/dev/null || echo 22)
PHASE=$(HOUR="$HOUR" WAKE_HOUR="$WAKE_HOUR" SLEEP_HOUR="$SLEEP_HOUR" python3 -c "
import os
hour, wake, sleep = int(os.environ['HOUR']), int(os.environ['WAKE_HOUR']), int(os.environ['SLEEP_HOUR'])
def in_range(h, start, end):
    if start <= end: return start <= h < end
    return h >= start or h < end
if in_range(hour, wake, (wake + 2) % 24): print('waking')
elif in_range(hour, sleep, (sleep + 1) % 24) or in_range(hour, (sleep + 1) % 24, wake): print('asleep')
elif in_range(hour, (sleep - 2) % 24, sleep): print('winding_down')
else: print('active')
")

# ── active goals (PFC) ─────────────────────────────────────────────────
GOALS="[]"
if [[ -f "$MEM/pfc-state.json" ]]; then
    GOALS=$(jq -c '[.goals[]? | select(.status == "active") | .description]' \
      "$MEM/pfc-state.json" 2>/dev/null || echo "[]")
fi

# ── attention focus (gate) ─────────────────────────────────────────────
FOCUS="[]"
if [[ -f "$MEM/thalamus-state.json" ]]; then
    FOCUS=$(jq -c '.attentionFocus // []' "$MEM/thalamus-state.json" 2>/dev/null || echo "[]")
fi

# ── neuromod snapshot (neutral defaults when the vector is absent) ─────
if [[ -x "$SCRIPT_DIR/get-neuromod.sh" ]]; then
    NEURO=$(bash "$SCRIPT_DIR/get-neuromod.sh" --json 2>/dev/null || echo "")
    if [[ -n "$NEURO" ]] && jq -e '.modulators' <<< "$NEURO" > /dev/null 2>&1; then
        SNAP=$(jq -c '{drive: (.modulators.dopamine.value // 0.5),
                       arousal: (.composites.arousal // 0.5),
                       cortisol: (.composites.stressIndex // 0.5),
                       sleepPressure: (.modulators.sleepPressure.value // 0)}' \
          <<< "$NEURO" 2>/dev/null || echo '{"drive":0.5,"arousal":0.5,"cortisol":0.5,"sleepPressure":0}')
    else
        SNAP='{"drive":0.5,"arousal":0.5,"cortisol":0.5,"sleepPressure":0}'
    fi
else
    SNAP='{"drive":0.5,"arousal":0.5,"cortisol":0.5,"sleepPressure":0}'
fi

jq --arg phase "$PHASE" --argjson goals "$GOALS" --argjson focus "$FOCUS" \
   --argjson snap "$SNAP" --arg now "$NOW" \
  '.attentionFocus = $focus
   | .context = {phase: $phase, goals: $goals, neuromod: $snap, lastUpdated: $now}' \
  "$WS" > "$WS.tmp.$$" && mv "$WS.tmp.$$" "$WS"