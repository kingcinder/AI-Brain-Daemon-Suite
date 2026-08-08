#!/bin/bash
# subscribe.sh — Poll the signal bus for events matching a pattern since the
# last checkpoint. Used by skills and the thalamus to consume signals without
# directly coupling to other skills' scripts.
#
# Usage:
#   subscribe.sh --subscriber <module> [--type <filter>] [--signal <filter>]
#                [--since <timestamp>] [--max 50] [--advance]
#
# Outputs: newline-delimited JSON objects (one per matching signal).
# --advance: after printing, update the subscriber's watermark so the next
#            poll won't re-read the same events.
#
# Checkpoint files live at $WORKSPACE/memory/.signal-checkpoints/<subscriber>

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SIGNAL_LOG="$WORKSPACE/memory/brain-signals.jsonl"
CHECKPOINT_DIR="$WORKSPACE/memory/.signal-checkpoints"

SUBSCRIBER=""
FILTER_TYPE=""
FILTER_SIGNAL=""
SINCE=""
MAX=50
ADVANCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subscriber) SUBSCRIBER="$2"; shift 2 ;;
        --type)       FILTER_TYPE="$2"; shift 2 ;;
        --signal)     FILTER_SIGNAL="$2"; shift 2 ;;
        --since)      SINCE="$2"; shift 2 ;;
        --max)        MAX="$2"; shift 2 ;;
        --advance)    ADVANCE=true; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$SUBSCRIBER" ]]; then
    echo "subscribe.sh: --subscriber is required" >&2
    exit 1
fi

mkdir -p "$CHECKPOINT_DIR"
CHECKPOINT_FILE="$CHECKPOINT_DIR/$SUBSCRIBER"

# Resolve the starting point
START_LINE=0
if [[ -z "$SINCE" ]] && [[ -f "$CHECKPOINT_FILE" ]]; then
    START_LINE=$(head -1 "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
fi

if [[ ! -f "$SIGNAL_LOG" ]]; then
    # No signals yet — still advance the watermark so we start from now
    if [[ "$ADVANCE" = true ]]; then
        wc -l < /dev/null > "$CHECKPOINT_FILE" 2>/dev/null || true
    fi
    exit 0
fi

TOTAL_LINES=$(wc -l < "$SIGNAL_LOG" 2>/dev/null || echo 0)
if [[ "$START_LINE" -ge "$TOTAL_LINES" ]]; then
    exit 0
fi

# Build jq filter
JQ_FILTER="."
if [[ -n "$FILTER_TYPE" ]]; then
    JQ_FILTER="$JQ_FILTER | select(.type == \"$FILTER_TYPE\")"
fi
if [[ -n "$FILTER_SIGNAL" ]]; then
    JQ_FILTER="$JQ_FILTER | select(.signal == \"$FILTER_SIGNAL\")"
fi

# Read new lines, filter, output
tail -n +$((START_LINE + 1)) "$SIGNAL_LOG" 2>/dev/null | \
    head -n "$MAX" | \
    jq -c "$JQ_FILTER" 2>/dev/null || true

# Advance watermark
if [[ "$ADVANCE" = true ]]; then
    echo "$TOTAL_LINES" > "$CHECKPOINT_FILE"
fi

exit 0
