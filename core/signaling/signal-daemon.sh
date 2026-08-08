#!/bin/bash
# signal-daemon.sh — Background dispatcher for the brain's signal bus.
#
# Watches brain-signals.jsonl for new events, routes each through the thalamus
# attention gate, and dispatches to target skills. Runs as a lightweight poll
# loop (every 30s) — the deep-brain-kernel already has the heavy scheduling;
# this is a dedicated signal processor.
#
# Usage:
#   signal-daemon.sh [--once]   # --once: process once and exit (for cron/direct jobs)
#
# Scheduled by deep-brain-kernel as a direct job every 2 minutes.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONCE=false
[[ "${1:-}" = "--once" ]] && ONCE=true

SIGNAL_LOG="$WORKSPACE/memory/brain-signals.jsonl"
CHECKPOINT_DIR="$WORKSPACE/memory/.signal-checkpoints"
DISPATCHER_CHECKPOINT="$CHECKPOINT_DIR/signal-daemon"

mkdir -p "$CHECKPOINT_DIR"

process_signals() {
    local subscriber="signal-daemon"
    local thalamus_gate="$WORKSPACE/skills/thalamus-memory/scripts/gate.sh"

    # Read new signals since last checkpoint
    local start_line=0
    [[ -f "$DISPATCHER_CHECKPOINT" ]] && start_line=$(head -1 "$DISPATCHER_CHECKPOINT" 2>/dev/null || echo 0)

    if [[ ! -f "$SIGNAL_LOG" ]]; then
        return 0
    fi

    local total_lines
    total_lines=$(wc -l < "$SIGNAL_LOG" 2>/dev/null || echo 0)
    if [[ "$start_line" -ge "$total_lines" ]]; then
        return 0
    fi

    # Process each new signal
    local count=0
    tail -n +$((start_line + 1)) "$SIGNAL_LOG" 2>/dev/null | while IFS= read -r line; do
        count=$((count + 1))
        [[ -z "$line" ]] && continue

        # If thalamus gate exists, route through it for attention filtering.
        # Otherwise, dispatch directly via route-signals.sh.
        if [[ -x "$thalamus_gate" ]]; then
            echo "$line" | "$thalamus_gate" --stdin 2>/dev/null || true
        else
            # Direct dispatch fallback: consult the routing table
            local source signal_type signal_name intensity payload
            source=$(echo "$line" | jq -r '.source // empty' 2>/dev/null || true)
            signal_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null || true)
            signal_name=$(echo "$line" | jq -r '.signal // empty' 2>/dev/null || true)
            intensity=$(echo "$line" | jq -r '.intensity // "0.5"' 2>/dev/null || echo "0.5")
            payload=$(echo "$line" | jq -r '.payload // {}' 2>/dev/null || echo "{}")

            [[ -z "$source" || -z "$signal_name" ]] && continue

            # Match against route-signals.sh and dispatch
            "$SCRIPT_DIR/route-signals.sh" 2>/dev/null | while IFS='|' read -r src sig tgt script args; do
                [[ "$src" = "$source" && "$sig" = "$signal_name" ]] || continue
                # Resolve template args
                resolved_args="${args//\{intensity\}/$intensity}"
                resolved_args="${resolved_args//\{signal\}/$signal_name}"
                resolved_args="${resolved_args//\{source\}/$source}"
                resolved_args="${resolved_args//\{energy\}/$intensity}"

                local target_path="$WORKSPACE/skills/$tgt/$script"
                if [[ -x "$target_path" ]]; then
                    # Fire and forget — don't block the dispatcher. Split the
                    # template honoring quotes (same xargs -n 1 fix as gate.sh):
                    # plain word-splitting mangles values like --trigger "a b".
                    local -a dispatch_args=()
                    if [ -n "$resolved_args" ]; then
                        mapfile -t dispatch_args < <(printf '%s\n' "$resolved_args" | xargs -n 1)
                    fi
                    bash "$target_path" "${dispatch_args[@]}" 2>/dev/null &
                fi
            done
        fi
    done

    # Advance checkpoint
    echo "$total_lines" > "$DISPATCHER_CHECKPOINT"
}

process_signals

if [[ "$ONCE" = false ]]; then
    # Continuous mode (for standalone daemon invocation, not typical)
    while true; do
        sleep 30
        process_signals
    done
fi

exit 0
