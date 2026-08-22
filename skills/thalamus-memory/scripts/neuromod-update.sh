#!/bin/bash
# neuromod-update.sh — Compose the global neuromodulator vector from the
# skill states, decay stale sources toward baseline, and write
# memory/neuromod-state.json. Chained from the neuromod_update daemon job
# (minutes 6,21,36,51); ends by running workspace-refresh.sh so the
# workspace context block is assembled from the fresh vector.
#
# Read-primary / fail-open: every source read is optional. A missing source
# contributes 0 to its term and is listed in missingSources; an all-missing
# source set yields the baselines. Never exits non-zero because a source is
# absent.
#
# Hardened write: flock + $$-scoped tmp + atomic mv (2026-08-08 audit pattern).

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEM="$WORKSPACE/memory"
OUT="$MEM/neuromod-state.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$MEM"
exec 200>"$OUT.lock"
flock 200

# ── read_field <file> <jq filter> <default> — fail-open reader ─────────
read_field() {
    local file="$1" filt="$2" default="$3"
    if [[ -f "$file" ]]; then
        jq -r "$filt" "$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# recency helper (hours since lastUpdated, or "" if absent/broken)
read_age() {
    local file="$1"
    [[ -f "$file" ]] || { echo ""; return; }
    local lu
    lu=$(jq -r '.lastUpdated // ""' "$file" 2>/dev/null || echo "")
    if [[ -z "$lu" || "$lu" = "null" ]]; then
        echo ""
        return
    fi
    local epoch_now epoch_lu
    epoch_now=$(date -u +%s)
    epoch_lu=$(date -u -d "$lu" +%s 2>/dev/null || date -u -d "${lu%Z}Z" +%s 2>/dev/null || echo "")
    if [[ -z "$epoch_lu" ]]; then
        echo ""
    else
        echo "scale=4; ($epoch_now - $epoch_lu) / 3600" | bc 2>/dev/null || echo ""
    fi
}

# ── Read source fields ─────────────────────────────────────────────────
DRIVE=$(read_field "$MEM/reward-state.json" '.drive // 0.5' "0.5")
HAS_REWARD=$(read_field "$MEM/reward-state.json" '([.recentRewards[]?] | length > 0) | if . then 1 else 0 end' "0")
HAS_ANTICIPATION=$(read_field "$MEM/reward-state.json" '([.anticipating[]?] | length > 0) | if . then 1 else 0 end' "0")

VALENCE=$(read_field "$MEM/emotional-state.json" '.dimensions.valence // 0.5' "0.5")
AROUSAL=$(read_field "$MEM/emotional-state.json" '.dimensions.arousal // 0.5' "0.5")

CONFLICT_LOAD=$(read_field "$MEM/conflict-state.json" '.conflictLoad // 0.5' "0.5")
ACC_ACTIVE=$(read_field "$MEM/acc-state.json" '([.activePatterns[]?] | length) | if . > 0 then 1 else 0 end' "0")

INS_LOAD=$(read_field "$MEM/interoceptive-state.json" '.channels.cognitiveLoad // 0.3' "0.3")
INS_GUT=$(read_field "$MEM/interoceptive-state.json" '.channels.gutSignal // 0.2' "0.2")

# mean relationship trust
AVG_TRUST=$(read_field "$MEM/social-state.json" \
  '([.relationships[].trust?] | if length > 0 then (add / length) else 0.5 end)' "0.5")

# recent heartbeat activity (beat within 30 min -> 1)
RECENT_ACTIVITY=$(read_field "$MEM/heartbeat-state.json" \
  '((.lastBeat // "") != "") | if . then 1 else 0 end' "0")

# attentionFocus length (gate), capped at 3 in the formula
FOCUS_LEN=$(read_field "$MEM/thalamus-state.json" \
  '([.attentionFocus[]?] | if length > 3 then 3 else length end) // 0' "0")

# ── sleep pressure: hours since wake / 24, 0 while asleep ──────────────
HOUR=$(date -u +%H | sed 's/^0//'); [ -z "$HOUR" ] && HOUR=0
WAKE_HOUR=$(read_field "$MEM/heartbeat-state.json" '.circadian.wakeHour // 8' "8")
SLEEP_HOUR=$(read_field "$MEM/heartbeat-state.json" '.circadian.sleepHour // 22' "22")
ASLEEP=$(HOUR="$HOUR" WAKE_HOUR="$WAKE_HOUR" SLEEP_HOUR="$SLEEP_HOUR" python3 -c "
import os
h, w, s = int(os.environ['HOUR']), int(os.environ['WAKE_HOUR']), int(os.environ['SLEEP_HOUR'])
def in_range(h, start, end):
    if start <= end: return start <= h < end
    return h >= start or h < end
print('1' if (in_range(h, s, (s+1)%24) or in_range(h, (s+1)%24, w)) else '0')
")
if [[ "$ASLEEP" = "1" ]]; then
    SLEEP_PRESSURE="0"
else
    HOURS_SINCE_WAKE=$(( (HOUR - WAKE_HOUR + 24) % 24 ))
    SLEEP_PRESSURE=$(echo "scale=4; if ($HOURS_SINCE_WAKE / 24 > 1.0) 1.0 else $HOURS_SINCE_WAKE / 24" | bc 2>/dev/null || echo "0")
fi

# ── clamp helper ───────────────────────────────────────────────────────
clamp() { echo "scale=4; if ($1 > 1.0) 1.0 else if ($1 < 0) 0 else $1" | bc 2>/dev/null || echo "0.5"; }

# ── Neuromodulator formulas ────────────────────────────────────────────
DOPAMINE=$(clamp "0.5 + 0.6*($DRIVE - 0.5) + 0.15*$HAS_REWARD + 0.10*$HAS_ANTICIPATION")
NORADRENALINE=$(clamp "0.5 + 1.0*($AROUSAL - 0.5) + 0.25*($INS_LOAD - 0.3) + 0.20*$RECENT_ACTIVITY")
SEROTONIN=$(clamp "0.5 + 0.8*($VALENCE - 0.5)")
ACETYLCHOLINE=$(clamp "0.5 + 0.10*$FOCUS_LEN + 0.30*($CONFLICT_LOAD - 0.5)")
CORTISOL=$(clamp "0.5 + 0.50*($CONFLICT_LOAD - 0.5) + 0.25*$INS_GUT + 0.20*$ACC_ACTIVE")
OXYTOCIN=$(clamp "0.5 + 0.8*($AVG_TRUST - 0.5)")

# ── stale-source pull toward baseline (sources older than 24h) ─────────
pull() {
    echo "scale=4; $1 + 0.15*($2 - $1)" | bc 2>/dev/null || echo "$1"
}
REWARD_AGE=$(read_age "$MEM/reward-state.json")
EMOTION_AGE=$(read_age "$MEM/emotional-state.json")
CONFLICT_AGE=$(read_age "$MEM/conflict-state.json")
INS_AGE=$(read_age "$MEM/interoceptive-state.json")
SOCIAL_AGE=$(read_age "$MEM/social-state.json")
BEAT_AGE=$(read_age "$MEM/heartbeat-state.json")
THAL_AGE=$(read_age "$MEM/thalamus-state.json")

[ -n "$REWARD_AGE" ]  && (( $(echo "$REWARD_AGE > 24" | bc -l 2>/dev/null || echo 0) )) && DOPAMINE=$(pull "$DOPAMINE" 0.5)
[ -n "$EMOTION_AGE" ] && (( $(echo "$EMOTION_AGE > 24" | bc -l 2>/dev/null || echo 0) )) && NORADRENALINE=$(pull "$NORADRENALINE" 0.5) && SEROTONIN=$(pull "$SEROTONIN" 0.5)
[ -n "$CONFLICT_AGE" ] && (( $(echo "$CONFLICT_AGE > 24" | bc -l 2>/dev/null || echo 0) )) && ACETYLCHOLINE=$(pull "$ACETYLCHOLINE" 0.5) && CORTISOL=$(pull "$CORTISOL" 0.5)
[ -n "$SOCIAL_AGE" ]   && (( $(echo "$SOCIAL_AGE > 24" | bc -l 2>/dev/null || echo 0) ))   && OXYTOCIN=$(pull "$OXYTOCIN" 0.5)
[ -n "$BEAT_AGE" ]     && (( $(echo "$BEAT_AGE > 24" | bc -l 2>/dev/null || echo 0) ))     && SLEEP_PRESSURE=$(pull "$SLEEP_PRESSURE" 0)

# Re-clamp after decay pulls (the pull may push a clamped value above/below range)
DOPAMINE=$(clamp "$DOPAMINE")
NORADRENALINE=$(clamp "$NORADRENALINE")
SEROTONIN=$(clamp "$SEROTONIN")
ACETYLCHOLINE=$(clamp "$ACETYLCHOLINE")
CORTISOL=$(clamp "$CORTISOL")
OXYTOCIN=$(clamp "$OXYTOCIN")
SLEEP_PRESSURE=$(clamp "$SLEEP_PRESSURE")

# ── missingSources (only the ones we actually looked for) ──────────────
MISSING="[]"
for pair in "reward-state.json:reward" "emotional-state.json:emotion" \
            "conflict-state.json:conflict" "interoceptive-state.json:insula" \
            "social-state.json:social" "heartbeat-state.json:heartbeat" \
            "thalamus-state.json:thalamus" "acc-state.json:acc"; do
    f="${pair%%:*}"; label="${pair##*:}"
    if [[ ! -f "$MEM/$f" ]]; then
        MISSING=$(echo "$MISSING" | jq --arg l "$label" '. + [$l]')
    fi
done

# ── composites ─────────────────────────────────────────────────────────
AROUSAL_C=$(echo "scale=4; 0.6*$NORADRENALINE + 0.4*$ACETYLCHOLINE" | bc 2>/dev/null || echo "0.5")
VALENCE_C=$(echo "scale=4; 0.7*$DOPAMINE + 0.3*$SEROTONIN" | bc 2>/dev/null || echo "0.5")
STRESS_C="$CORTISOL"

jq -n \
  --arg updated "$NOW" \
  --argjson dopamine "$DOPAMINE" --argjson noradrenaline "$NORADRENALINE" \
  --argjson serotonin "$SEROTONIN" --argjson acetylcholine "$ACETYLCHOLINE" \
  --argjson cortisol "$CORTISOL" --argjson oxytocin "$OXYTOCIN" \
  --argjson sleepPressure "$SLEEP_PRESSURE" \
  --argjson arousal "$AROUSAL_C" --argjson valence "$VALENCE_C" --argjson stress "$STRESS_C" \
  --argjson missing "$MISSING" \
  '{version: 1,
    updatedAt: $updated,
    modulators: {
      dopamine:      {value: $dopamine,      source: "vta.reward-state.drive+reward+anticipation"},
      noradrenaline: {value: $noradrenaline, source: "amygdala.arousal+insula.load+heartbeat"},
      serotonin:     {value: $serotonin,     source: "amygdala.valence"},
      acetylcholine: {value: $acetylcholine, source: "gate.attentionFocus+acc.conflictLoad"},
      cortisol:      {value: $cortisol,      source: "acc.conflictLoad+insula.gut+acc.activePatterns"},
      oxytocin:      {value: $oxytocin,      source: "social.trust"},
      sleepPressure: {value: $sleepPressure, source: "circadian.phase+clock"}
    },
    composites: {arousal: $arousal, valence: $valence, stressIndex: $stress},
    missingSources: $missing
  }' > "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"

# Chained step: assemble the workspace context block from the fresh vector.
# Drop the neuromod lock first — workspace-refresh.sh calls get-neuromod.sh
# which tries to acquire this same lock, creating a self-deadlock.
exec 200>&-
if [[ -x "$SCRIPT_DIR/workspace-refresh.sh" ]]; then
    bash "$SCRIPT_DIR/workspace-refresh.sh" || true
fi