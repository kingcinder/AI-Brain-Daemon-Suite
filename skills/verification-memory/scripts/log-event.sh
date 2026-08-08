#!/bin/bash
# log-event.sh — Append a verification event to brain-events.jsonl
# Usage: log-event.sh --type <event_type> --signal <signal_name> [--source <module>]
set -u

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
EVENT_LOG="$WORKSPACE/memory/brain-events.jsonl"

TYPE=""; SIGNAL=""; SOURCE="verification-memory"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --signal) SIGNAL="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$TYPE" ] || [ -z "$SIGNAL" ]; then
    echo "log-event.sh: --type and --signal are required" >&2
    exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$WORKSPACE/memory"
echo "{\"ts\":\"$NOW\",\"type\":\"$SOURCE\",\"event\":\"$TYPE\",\"signal\":\"$SIGNAL\",\"published\":true}" >> "$EVENT_LOG" 2>/dev/null || true
