#!/bin/bash
# gate.sh — Thalamic attention gate: score, filter, and dispatch signals.
#
# This is the core of the thalamus skill. It reads incoming signals from the
# signal bus (either from stdin or by polling brain-signals.jsonl), scores
# each against the five attention dimensions, and dispatches passing signals
# to target skills via route-signals.sh.
#
# Usage:
#   gate.sh --process              # Process all pending signals
#   gate.sh --stdin                # Read a single signal envelope from stdin
#   gate.sh --status               # Print current attention state
#   gate.sh --boost-goal "<desc>"  # Boost attention weight for a specific goal
#   gate.sh --feedback attend <target> [--weight <0-1>] [--from <skill>]
#                                 # Cortico-thalamic feedback: cortex tells the
#                                 # gate to amplify <target> (a source, signal
#                                 # name, or goal text) — top-down attention.
#   gate.sh --feedback release <target> [--from <skill>]
#                                 # Cortico-thalamic feedback: cortex stands
#                                 # attention down from <target>.
#
# The relay is bidirectional, modeled on cortico-thalamo-cortical loops:
#   feedforward: signals score + dispatch to cortex (the --process/--stdin legs)
#   feedback:    cortical attend/release directives modulate attention focus
#                and per-channel gain (the layer-6 / TRN top-down path).
#                Every dispatch and directive is tallied in .relay.stats so
#                the loop is observable, not just implicit.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CORE_DIR="$(cd "$SKILL_DIR/../../core" && pwd)"
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"
PFC_STATE="$WORKSPACE/memory/pfc-state.json"
EXEC_LOAD="$WORKSPACE/memory/executive-load.json"
SIGNAL_LOG="$WORKSPACE/memory/brain-signals.jsonl"
CHECKPOINT_DIR="$WORKSPACE/memory/.signal-checkpoints"
GATE_CHECKPOINT="$CHECKPOINT_DIR/thalamus-gate"

mkdir -p "$CHECKPOINT_DIR" "$(dirname "$STATE_FILE")"

# Serialize read-modify-write against decay.sh and concurrent gate
# invocations (thalamus_gate + signal_dispatch jobs, manual runs) — all
# write thalamus-state.json.
exec 200>"$STATE_FILE.lock"
flock 200

MODE="process"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --process)    MODE="process"; shift ;;
        --stdin)      MODE="stdin"; shift ;;
        --status)     MODE="status"; shift ;;
        --boost-goal) MODE="boost"; BOOST_GOAL="$2"; shift 2 ;;
        --feedback)   MODE="feedback"; FEEDBACK_KIND="$2"; FEEDBACK_TARGET="$3"; shift 3 ;;
        --weight)     FEEDBACK_WEIGHT="$2"; shift 2 ;;
        --from)       FEEDBACK_FROM="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ── Initialize state if missing ─────────────────────────────────────────
_init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": "",
  "attentionFocus": [],
  "suppressedQueue": [],
  "stats": {
    "totalSignalsProcessed": 0,
    "amplified": 0,
    "passed": 0,
    "attenuated": 0,
    "suppressed": 0,
    "dispatchedToTargets": 0
  },
  "gateSensitivity": 0.5,
  "lastGateRun": "",
  "relay": {
    "feedback": [],
    "history": [],
    "stats": {"feedforward": 0, "feedback": 0, "lastLoopAt": ""}
  }
}
EOF
    fi
}

# ── Seed the relay block into a pre-relay state file ────────────────────
_ensure_relay() {
    # A state file written before the relay existed lacks .relay; the jq
    # below auto-vivifies keys on path assignment anyway, but a clean seed
    # keeps the schema explicit and idempotent on every later run.
    local tmp="$STATE_FILE.tmp.$$"
    jq 'if has("relay") then . else . + {relay: {feedback: [], history: [], stats: {feedforward: 0, feedback: 0, lastLoopAt: ""}}} end' \
       "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || true
}

# ── Read current PFC goals for relevance matching ───────────────────────
_get_active_goals() {
    if [[ -f "$PFC_STATE" ]]; then
        jq -r '[.goals[]? | select(.status == "active") | .description] | join("\n")' "$PFC_STATE" 2>/dev/null || true
    fi
}

# ── Read executive load ─────────────────────────────────────────────────
_get_exec_load() {
    if [[ -f "$EXEC_LOAD" ]]; then
        jq -r '.E // 0.5' "$EXEC_LOAD" 2>/dev/null || echo "0.5"
    else
        echo "0.5"
    fi
}

# ── Compute circadian gain ──────────────────────────────────────────────
_get_circadian_gain() {
    local hour
    hour=$(date -u +%H)
    hour=$((10#$hour))
    # Active hours (8-20): gain 1.5
    # Transition (6-8, 20-22): gain 1.0
    # Sleep (22-6): gain 0.5
    if [[ $hour -ge 8 && $hour -lt 20 ]]; then
        echo "1.5"
    elif [[ $hour -ge 6 && $hour -lt 8 ]] || [[ $hour -ge 20 && $hour -lt 22 ]]; then
        echo "1.0"
    else
        echo "0.5"
    fi
}

# ── Read the global neuromodulator vector (neutral when absent) ─────────
_get_neuromod() {
    # Reads once per call; called from within _score_signal (a pipeline
    # subshell), so state set here cannot be hoisted to _process.
    if [[ -x "$SCRIPT_DIR/get-neuromod.sh" ]]; then
        NEURO_NA=$("$SCRIPT_DIR/get-neuromod.sh" --get noradrenaline 2>/dev/null || echo "0.5")
        NEURO_DA=$("$SCRIPT_DIR/get-neuromod.sh" --get dopamine 2>/dev/null || echo "0.5")
        NEURO_ACH=$("$SCRIPT_DIR/get-neuromod.sh" --get acetylcholine 2>/dev/null || echo "0.5")
        NEURO_CORT=$("$SCRIPT_DIR/get-neuromod.sh" --get cortisol 2>/dev/null || echo "0.5")
        NEURO_SP=$("$SCRIPT_DIR/get-neuromod.sh" --get sleepPressure 2>/dev/null || echo "0")
        NEURO_PRESENT=$([[ -f "$WORKSPACE/memory/neuromod-state.json" ]] && echo "1" || echo "0")
        # Absent vector = NO stress: cortisol must read 0 (so the out-of-focus
        # suppression factor is (1 - 0.25*0) = 1.0), NOT the 0.5 baseline —
        # the 0.5 baseline would scale every out-of-focus score by 0.875 on a
        # fresh install, violating the neutral-by-default guarantee.
        [[ "$NEURO_PRESENT" = "1" ]] || NEURO_CORT="0"
    else
        NEURO_NA="0.5"; NEURO_DA="0.5"; NEURO_ACH="0.5"; NEURO_CORT="0"; NEURO_SP="0"
        NEURO_PRESENT="0"
    fi
}

# ── Score a single signal ───────────────────────────────────────────────
_score_signal() {
    local signal_json="$1"
    local goals
    goals=$(_get_active_goals)

    local source signal_name intensity
    source=$(echo "$signal_json" | jq -r '.source // ""' 2>/dev/null || echo "")
    signal_name=$(echo "$signal_json" | jq -r '.signal // ""' 2>/dev/null || echo "")
    intensity=$(echo "$signal_json" | jq -r '.intensity // "0.5"' 2>/dev/null || echo "0.5")

    # 1. Goal relevance: does signal text match any active goal description?
    local goal_relevance=0.0
    if [[ -n "$goals" ]]; then
        local combined
        combined="$source $signal_name $(echo "$signal_json" | jq -r '.payload | tostring' 2>/dev/null || echo '')"
        while IFS= read -r goal; do
            [[ -z "$goal" ]] && continue
            # Simple word overlap scoring — literal substring match (glob with
            # quoted RHS), NOT regex: goal words containing regex metacharacters
            # (., +, [, etc.) must match literally.
            local overlap=0
            for word in $goal; do
                [[ "$combined" == *"$word"* ]] && overlap=$((overlap + 1))
            done
            # Normalize: each overlapping word adds 0.15, capped at 1.0
            local gscore
            gscore=$(echo "scale=4; if ($overlap > 0) $(echo "scale=4; $overlap * 0.15" | bc) else 0" | bc 2>/dev/null || echo "0")
            goal_relevance=$(echo "scale=4; if ($gscore > $goal_relevance) $gscore else $goal_relevance" | bc 2>/dev/null || echo "$goal_relevance")
        done <<< "$goals"
        goal_relevance=$(echo "scale=4; if ($goal_relevance > 1.0) 1.0 else $goal_relevance" | bc 2>/dev/null || echo "$goal_relevance")
    fi

    # 2. Novelty bonus: check if signal type is recently seen
    local novelty=0.3
    if [[ -f "$STATE_FILE" ]]; then
        local recent_count
        recent_count=$(jq --arg src "$source" --arg sig "$signal_name" \
            '[.suppressedQueue[]? | select(.signal.source == $src and .signal.signal == $sig)] | length' \
            "$STATE_FILE" 2>/dev/null || echo "0")
        # Less suppressed = more novel
        novelty=$(echo "scale=4; if ($recent_count > 5) 0.1 else if ($recent_count > 2) 0.3 else if ($recent_count > 0) 0.5 else 0.7" | bc 2>/dev/null || echo "0.3")
    fi

    # 3. Urgency: from intensity and source priority, chemically modulated
    #    (noradrenaline: urgency_factor = 0.7 + 0.6*NA, range 0.7-1.3).
    _get_neuromod
    local source_priority=0.5
    case "$source" in
        acc-error-memory|anterior-cingulate-memory) source_priority=0.9 ;;
        amygdala-memory|heartbeat-memory) source_priority=0.7 ;;
        prefrontal-cortex-memory) source_priority=0.8 ;;
        vta-memory) source_priority=0.6 ;;
        *) source_priority=0.5 ;;
    esac
    local urgency urgency_factor
    urgency_factor=$(echo "scale=4; 0.7 + 0.6 * $NEURO_NA" | bc 2>/dev/null || echo "1.0")
    urgency=$(echo "scale=4; $intensity * $source_priority * $urgency_factor" | bc 2>/dev/null || echo "0.5")

    # 4. Load headroom: inverse of executive load
    local exec_load
    exec_load=$(_get_exec_load)
    local headroom
    headroom=$(echo "scale=4; 1.0 - $exec_load" | bc 2>/dev/null || echo "0.5")
    if (( $(echo "$headroom < 0" | bc -l 2>/dev/null) )); then
        headroom=0.0
    fi

    # 5. Circadian gain
    local circadian
    circadian=$(_get_circadian_gain)

    # Final score — dopamine modulates the goal-relevance weight
    # (0.35*(0.8+0.4*DA), range 0.28-0.42); sleep pressure floors the
    # circadian gain (gain' = gain*(1 - 0.3*SP)).
    local da_weight circadian_final score
    da_weight=$(echo "scale=6; 0.35 * (0.8 + 0.4 * $NEURO_DA)" | bc 2>/dev/null || echo "0.35")
    circadian_final=$(echo "scale=4; $circadian * (1.0 - 0.3 * $NEURO_SP)" | bc 2>/dev/null || echo "$circadian")
    score=$(echo "scale=6; ($goal_relevance * $da_weight + $novelty * 0.15 + $urgency * 0.25 + $headroom * 0.25) * $circadian_final" | bc 2>/dev/null || echo "0.3")

    # Focus sharpening + off-focus suppression (ACh and cortisol act only on
    # signals OUTSIDE the boosted attentionFocus list).
    local in_focus=0
    if jq -e --arg s "$signal_name" --arg src "$source" \
      '[.attentionFocus[]? | contains($s) or contains($src)] | any' \
      "$STATE_FILE" > /dev/null 2>&1; then
        in_focus=1
    fi
    if [[ "$in_focus" -eq 0 ]]; then
        if (( $(echo "$NEURO_ACH > 0.6" | bc -l 2>/dev/null) )); then
            score=$(echo "scale=6; $score * (1.0 - 0.3 * (($NEURO_ACH - 0.6) / 0.4))" | bc 2>/dev/null || echo "$score")
        fi
        score=$(echo "scale=6; $score * (1.0 - 0.25 * $NEURO_CORT)" | bc 2>/dev/null || echo "$score")
    fi

    # ── Cortico-thalamic feedback gain (the feedback leg of the relay) ──
    # A signal whose source or signal name matches an active attend directive
    # is amplified by (1.0 + 0.5×weight) — the layer-6 / TRN top-down bias
    # that makes attended channels pass (or amplify) more easily. No attend
    # directives → gain is exactly 1.0 → byte-identical to a run without the
    # relay (neutral-by-default, protecting the regression lock).
    local relay_gain=0
    local targets
    targets=$(jq -r '[.relay.feedback[]? | select(.kind == "attend") | .target] | .[]' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$targets" ]]; then
        local combined_lc
        combined_lc=$(printf '%s' "$source $signal_name" | tr '[:upper:]' '[:lower:]')
        while IFS= read -r tgt; do
            [[ -z "$tgt" ]] && continue
            # Literal substring match (quoted RHS glob), case-insensitive —
            # consistent with the attentionFocus in-focus check above.
            if [[ "$combined_lc" == *"$(printf '%s' "$tgt" | tr '[:upper:]' '[:lower:]')"* ]]; then
                local w
                w=$(jq -r --arg tgt "$tgt" '[.relay.feedback[]? | select(.kind == "attend" and .target == $tgt) | .weight // 0.6] | max' "$STATE_FILE" 2>/dev/null || echo "0.6")
                relay_gain=$(echo "scale=4; if ($w > $relay_gain) $w else $relay_gain" | bc 2>/dev/null || echo "$relay_gain")
            fi
        done <<< "$targets"
    fi
    if (( $(echo "$relay_gain > 0" | bc -l 2>/dev/null) )); then
        score=$(echo "scale=6; $score * (1.0 + 0.5 * $relay_gain)" | bc 2>/dev/null || echo "$score")
    fi

    # Determine action
    local action
    if (( $(echo "$score >= 0.70" | bc -l 2>/dev/null) )); then
        action="amplify"
    elif (( $(echo "$score >= 0.40" | bc -l 2>/dev/null) )); then
        action="pass"
    elif (( $(echo "$score >= 0.20" | bc -l 2>/dev/null) )); then
        action="attenuate"
    else
        action="suppress"
    fi

    # Output as JSON for downstream consumption
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
}

# ── Update state stats ──────────────────────────────────────────────────
_update_stats() {
    local action="$1"
    local tmp="$STATE_FILE.tmp.$$"
    jq --arg action "$action" \
       --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.stats.totalSignalsProcessed += 1 |
     .stats.amplified += (if $action == "amplify" then 1 else 0 end) |
     .stats.passed += (if $action == "pass" then 1 else 0 end) |
     .stats.attenuated += (if $action == "attenuate" then 1 else 0 end) |
     .stats.suppressed += (if $action == "suppress" then 1 else 0 end) |
     .stats.dispatchedToTargets += (if $action != "suppress" then 1 else 0 end) |
     .relay.stats.feedforward = ((.relay.stats.feedforward // 0) + 1) |
     .relay.stats.lastLoopAt = $now' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Dispatch to target skills via route-signals.sh ──────────────────────
_dispatch() {
    local source="$1" signal_name="$2" action="$3" intensity="$4" score="$5" raw_signal="$6"
    local route_script="$CORE_DIR/signaling/route-signals.sh"

    # Suppressed signals go to the pending queue, not dispatched
    if [[ "$action" = "suppress" ]]; then
        local tmp="$STATE_FILE.tmp.$$"
        jq --arg src "$source" --arg sig "$signal_name" --argjson intensity "$intensity" \
           --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
           --arg retry "$(date -u -d '+1 hour' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '.suppressedQueue += [{
            signal: {source: $src, signal: $sig},
            intensity: $intensity,
            suppressedAt: $now,
            retryAfter: $retry,
            reason: "gate score below threshold"
        }]' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
        return 0
    fi

    # Integrative State Layer: broadcast the passing signal to the global
    # workspace (event-driven currentFocus / recentBroadcasts).
    if [[ -x "$SCRIPT_DIR/broadcast.sh" ]]; then
        ( exec 200>&- 2>/dev/null || true
          bash "$SCRIPT_DIR/broadcast.sh" --source "$source" --signal "$signal_name" \
               --action "$action" --gate-score "$score" 2>/dev/null ) &
    fi

    # Determine dispatch intensity
    local dispatch_intensity="$intensity"
    if [[ "$action" = "amplify" ]]; then
        dispatch_intensity=$(echo "scale=4; if ($intensity * 1.3 > 1.0) 1.0 else $intensity * 1.3" | bc 2>/dev/null || echo "$intensity")
    elif [[ "$action" = "attenuate" ]]; then
        dispatch_intensity=$(echo "scale=4; $intensity * 0.5" | bc 2>/dev/null || echo "$intensity")
    fi

    # Look up target routes and dispatch
    if [[ -x "$route_script" ]]; then
        "$route_script" 2>/dev/null | while IFS='|' read -r src sig tgt script args; do
            [[ "$src" = "$source" && "$sig" = "$signal_name" ]] || continue

            # Resolve template placeholders
            local resolved_args="${args//\{intensity\}/$dispatch_intensity}"
            resolved_args="${resolved_args//\{signal\}/$signal_name}"
            resolved_args="${resolved_args//\{source\}/$source}"
            resolved_args="${resolved_args//\{energy\}/$dispatch_intensity}"

            # Resolve payload placeholders
            local payload_type payload_pattern payload_mitigation payload_description
            payload_type=$(echo "$raw_signal" | jq -r '.payload.type // ""' 2>/dev/null || echo "")
            payload_pattern=$(echo "$raw_signal" | jq -r '.payload.pattern // ""' 2>/dev/null || echo "")
            payload_mitigation=$(echo "$raw_signal" | jq -r '.payload.mitigation // ""' 2>/dev/null || echo "")
            payload_description=$(echo "$raw_signal" | jq -r '.payload.description // ""' 2>/dev/null || echo "")
            resolved_args="${resolved_args//\{payload_type\}/$payload_type}"
            resolved_args="${resolved_args//\{payload_pattern\}/$payload_pattern}"
            resolved_args="${resolved_args//\{payload_mitigation\}/$payload_mitigation}"
            resolved_args="${resolved_args//\{payload_description\}/$payload_description}"

            local target_path="$WORKSPACE/skills/$tgt/$script"
            if [[ -x "$target_path" ]]; then
                # Split the arg template on whitespace while honoring the quoted
                # values route-signals.sh emits (e.g. --trigger "gut discord")
                # instead of word-splitting them into broken fragments.
                local -a dispatch_args=()
                if [ -n "$resolved_args" ]; then
                    # xargs -n 1 emits one token per line so mapfile builds a
                    # real array (plain `xargs` would join every token onto one
                    # line → a single mangled argument).
                    mapfile -t dispatch_args < <(printf '%s\n' "$resolved_args" | xargs -n 1)
                fi
                # Drop the inherited gate lock in the background child so the
                # flock never outlives this gate run (children holding the
                # inherited fd would otherwise delay decay.sh / gate.sh).
                ( exec 200>&- 2>/dev/null || true
                  bash "$target_path" "${dispatch_args[@]}" 2>/dev/null ) &
            fi
        done
    fi
}

# ── Process pending signals ─────────────────────────────────────────────
_process() {
    _init_state
    _ensure_relay

    local start_line=0
    [[ -f "$GATE_CHECKPOINT" ]] && start_line=$(head -1 "$GATE_CHECKPOINT" 2>/dev/null || echo 0)

    if [[ ! -f "$SIGNAL_LOG" ]]; then
        return 0
    fi

    local total_lines
    total_lines=$(wc -l < "$SIGNAL_LOG" 2>/dev/null || echo 0)
    if [[ "$start_line" -ge "$total_lines" ]]; then
        return 0
    fi

    tail -n +$((start_line + 1)) "$SIGNAL_LOG" 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local scored action source signal_name intensity
        scored=$(_score_signal "$line")
        action=$(echo "$scored" | jq -r '.action' 2>/dev/null || echo "suppress")
        source=$(echo "$scored" | jq -r '.source' 2>/dev/null || echo "")
        signal_name=$(echo "$scored" | jq -r '.signal' 2>/dev/null || echo "")
        intensity=$(echo "$scored" | jq -r '.intensity' 2>/dev/null || echo "0.5")
        local gate_score
        gate_score=$(echo "$scored" | jq -r '.gateScore' 2>/dev/null || echo "0")

        _update_stats "$action"
        _dispatch "$source" "$signal_name" "$action" "$intensity" "$gate_score" "$line"
    done

    echo "$total_lines" > "$GATE_CHECKPOINT"

    # Update last run timestamp
    local tmp="$STATE_FILE.tmp.$$"
    jq --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.lastGateRun = $now' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Process single signal from stdin ────────────────────────────────────
_stdin_process() {
    _init_state
    _ensure_relay
    local raw_signal
    raw_signal=$(cat)
    [[ -z "$raw_signal" ]] && return 0

    local scored action source signal_name intensity gate_score
    scored=$(_score_signal "$raw_signal")
    action=$(echo "$scored" | jq -r '.action' 2>/dev/null || echo "suppress")
    source=$(echo "$scored" | jq -r '.source' 2>/dev/null || echo "")
    signal_name=$(echo "$scored" | jq -r '.signal' 2>/dev/null || echo "")
    intensity=$(echo "$scored" | jq -r '.intensity' 2>/dev/null || echo "0.5")
    gate_score=$(echo "$scored" | jq -r '.gateScore' 2>/dev/null || echo "0")

    _update_stats "$action"
    _dispatch "$source" "$signal_name" "$action" "$intensity" "$gate_score" "$raw_signal"

    # Emit the scored envelope so callers (tests, manual runs) can consume it.
    echo "$scored"
}

# ── Status display ──────────────────────────────────────────────────────
_status() {
    _init_state
    echo "🚦 Thalamus Attention Gate"
    echo "═══════════════════════════"
    echo ""
    if [[ -f "$STATE_FILE" ]]; then
        local total amp passed att supp disp focus
        total=$(jq -r '.stats.totalSignalsProcessed // 0' "$STATE_FILE")
        amp=$(jq -r '.stats.amplified // 0' "$STATE_FILE")
        passed=$(jq -r '.stats.passed // 0' "$STATE_FILE")
        att=$(jq -r '.stats.attenuated // 0' "$STATE_FILE")
        supp=$(jq -r '.stats.suppressed // 0' "$STATE_FILE")
        disp=$(jq -r '.stats.dispatchedToTargets // 0' "$STATE_FILE")
        focus=$(jq -r '.attentionFocus | join(", ")' "$STATE_FILE" 2>/dev/null || echo "none")
        local last_run
        last_run=$(jq -r '.lastGateRun // "never"' "$STATE_FILE")

        echo "Signals processed: $total"
        echo "  🔺 Amplified:  $amp"
        echo "  ✅ Passed:     $passed"
        echo "  🔻 Attenuated: $att"
        echo "  🚫 Suppressed: $supp"
        echo "  📤 Dispatched: $disp"
        echo ""
        echo "Attention focus: $focus"
        echo "Relay loop: $(jq -r '.relay.stats.feedforward // 0' "$STATE_FILE") feedforward · $(jq -r '.relay.stats.feedback // 0' "$STATE_FILE") feedback"
        local attends
        attends=$(jq -r '[.relay.feedback[]? | select(.kind == "attend") | .target] | if length > 0 then join(", ") else "none" end' "$STATE_FILE" 2>/dev/null || echo "none")
        echo "Attending (cortical feedback): $attends"
        echo "Gate sensitivity: $(jq -r '.gateSensitivity // 0.5' "$STATE_FILE")"
        echo "Circadian gain: $(_get_circadian_gain)×"
        echo "Last gate run: $last_run"
        echo ""
        local pending
        pending=$(jq -r '.suppressedQueue | length // 0' "$STATE_FILE")
        echo "Suppressed queue: $pending pending for retry"
    else
        echo "No state file yet — run --process first"
    fi
}

# ── Cortico-thalamic feedback directive (feedback leg of the relay) ────
_feedback() {
    _init_state
    if [[ -z "${FEEDBACK_TARGET:-}" ]]; then
        echo "gate.sh --feedback <attend|release> <target> [--weight <0-1>] [--from <skill>]" >&2
        echo "  target required (a source skill name, signal name, or goal text)" >&2
        exit 1
    fi
    if [[ -n "${FEEDBACK_WEIGHT:-}" ]] && ! [[ "$FEEDBACK_WEIGHT" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        echo "gate.sh: --weight must be a number (got '$FEEDBACK_WEIGHT')" >&2
        exit 1
    fi
    _ensure_relay

    local weight="${FEEDBACK_WEIGHT:-0.6}"
    # Clamp weight to [0,1] — beyond 1.0 would overdrive the gain; negative
    # weights are "release", not attend.
    weight=$(echo "scale=4; if ($weight > 1.0) 1.0 else if ($weight < 0.0) 0.0 else $weight" | bc 2>/dev/null || echo "0.6")
    local from="${FEEDBACK_FROM:-cortex}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp="$STATE_FILE.tmp.$$"

    case "$FEEDBACK_KIND" in
        attend)
            jq --arg tgt "$FEEDBACK_TARGET" --arg w "$weight" --arg from "$from" --arg now "$now" \
            '.attentionFocus = ([$tgt] + [.attentionFocus[]? | select(. != $tgt)] | .[0:10])
             | .relay.feedback = ([{kind:"attend", target:$tgt, weight:($w | tonumber), from:$from, issuedAt:$now}] + [.relay.feedback[]? | select(.target != $tgt)])[0:20]
             | .relay.history = ([{kind:"attend", target:$tgt, weight:($w | tonumber), from:$from, issuedAt:$now}] + (.relay.history // []))[0:10]
             | .relay.stats.feedback = ((.relay.stats.feedback // 0) + 1)
             | .relay.stats.lastLoopAt = $now
             | .lastUpdated = $now' \
            "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            local gain
            gain=$(echo "scale=2; 1.0 + 0.5 * $weight" | bc 2>/dev/null || echo "1.3")
            echo "🚦 Thalamus relay: cortex now attending '$FEEDBACK_TARGET' (gain ×$gain)"
            ;;
        release)
            jq --arg tgt "$FEEDBACK_TARGET" --arg from "$from" --arg now "$now" \
            '.attentionFocus = [.attentionFocus[]? | select(. != $tgt)]
             | .relay.feedback = [.relay.feedback[]? | select(.target != $tgt)]
             | .relay.history = ([{kind:"release", target:$tgt, from:$from, issuedAt:$now}] + (.relay.history // []))[0:10]
             | .relay.stats.feedback = ((.relay.stats.feedback // 0) + 1)
             | .relay.stats.lastLoopAt = $now
             | .lastUpdated = $now' \
            "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            echo "🚦 Thalamus relay: attention released from '$FEEDBACK_TARGET'"
            ;;
        *)
            echo "gate.sh: unknown feedback kind '$FEEDBACK_KIND' (expected attend|release)" >&2
            exit 1
            ;;
    esac
}

# ── Boost a goal's attention weight ─────────────────────────────────────
_boost() {
    _init_state
    local tmp="$STATE_FILE.tmp.$$"
    jq --arg goal "$BOOST_GOAL" \
    'if (.attentionFocus | index($goal)) then . else .attentionFocus += [$goal] end' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    echo "🚦 Boosted attention for goal: $BOOST_GOAL"
}

# ── Dispatch ────────────────────────────────────────────────────────────
case "$MODE" in
    process) _process ;;
    stdin)   _stdin_process ;;
    status)  _status ;;
    boost)   _boost ;;
    feedback) _feedback ;;
    *)       echo "Unknown mode: $MODE" >&2; exit 1 ;;
esac

# Keep the 🚦 Thalamus tab fresh with the latest gate state — but only on
# state-mutating modes. --status is read-only and called frequently (e.g.
# session startup per AGENTS.md); it must not rebuild the dashboard.
if [ "$MODE" != "status" ]; then
    [ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && bash "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true
fi

exit 0
