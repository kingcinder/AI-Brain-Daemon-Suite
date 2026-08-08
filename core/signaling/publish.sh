#!/bin/bash
# publish.sh — Emit a typed event onto the brain-wide signal bus.
#
# This is the "write" side of the event bus. Skills call this instead of
# directly invoking another skill's script. Events land in a structured,
# append-only log that the signal daemon and thalamus consume.
#
# Usage:
#   publish.sh --type <event_type> --source <module> --signal <signal_name> \
#              [--intensity <0-1>] [--target <module>] [--payload '{"k":"v"}']
#
# Signal routing table is in route-signals.sh — this script is fire-and-forget.
# Every publish is best-effort; if WORKSPACE is unwritable, it fails silently
# with a warning to stderr, never crashing the caller.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SIGNAL_LOG="$WORKSPACE/memory/brain-signals.jsonl"
EVENT_LOG="$WORKSPACE/memory/brain-events.jsonl"

# ── Parse args ──────────────────────────────────────────────────────────
TYPE=""
SOURCE=""
SIGNAL=""
INTENSITY=""
TARGET=""
PAYLOAD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)       TYPE="$2"; shift 2 ;;
        --source)     SOURCE="$2"; shift 2 ;;
        --signal)     SIGNAL="$2"; shift 2 ;;
        --intensity)  INTENSITY="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --payload)    PAYLOAD="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$TYPE" || -z "$SOURCE" || -z "$SIGNAL" ]]; then
    echo "publish.sh: --type, --source, and --signal are required" >&2
    echo "Usage: publish.sh --type <event_type> --source <module> --signal <signal_name> [...]" >&2
    exit 1
fi

# ── Build the signal envelope ───────────────────────────────────────────
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Use --arg + fromjson for robust payload handling: empty → {},
# invalid JSON → {} (fail open). Avoids --argjson parsing edge cases.
_payload_json="${PAYLOAD:-}"
[[ -z "$_payload_json" ]] && _payload_json="{}"

ENVELOPE=$(jq -nc \
    --arg ts "$NOW" \
    --arg type "$TYPE" \
    --arg source "$SOURCE" \
    --arg signal "$SIGNAL" \
    --arg intensity "${INTENSITY:-}" \
    --arg target "${TARGET:-}" \
    --arg payload_raw "$_payload_json" \
'{
    ts: $ts,
    type: $type,
    source: $source,
    signal: $signal,
    intensity: (if $intensity == "" then null else ($intensity | tonumber) end),
    target: (if $target == "" then null else $target end),
    payload: ($payload_raw | fromjson? // {})
}')

# ── Append to signal log ────────────────────────────────────────────────
SIGNAL_DIR=$(dirname "$SIGNAL_LOG")
if ! mkdir -p "$SIGNAL_DIR" 2>/dev/null; then
    echo "publish.sh: WARNING: cannot create signal dir $SIGNAL_DIR — signal dropped" >&2
    exit 0
fi

if ! echo "$ENVELOPE" >> "$SIGNAL_LOG" 2>/dev/null; then
    echo "publish.sh: WARNING: cannot write to $SIGNAL_LOG — signal dropped" >&2
    exit 0
fi

# Also append to the legacy brain-events.jsonl for backward compatibility
# (skills that still read brain-events directly, not the signal log)
echo "{\"ts\":\"$NOW\",\"type\":\"$SOURCE\",\"event\":\"$TYPE\",\"signal\":\"$SIGNAL\",\"published\":true}" >> "$EVENT_LOG" 2>/dev/null || true

exit 0
