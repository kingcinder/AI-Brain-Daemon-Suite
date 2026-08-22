#!/bin/bash
# broadcast.sh — Event-driven global-workspace write: called by gate.sh on
# every non-suppressed dispatch with the scored signal envelope. Appends
# currentFocus + a recentBroadcasts entry (ring capped at 5) to
# memory/workspace.json.
#
# Usage: broadcast.sh --source <s> --signal <sig> --action <a> --gate-score <g>
# All args optional; the file is created on first use.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
MEM="$WORKSPACE/memory"
WS="$MEM/workspace.json"

mkdir -p "$MEM"
exec 200>"$WS.lock"
flock 200

SOURCE=""; SIGNAL=""; ACTION=""; GATE_SCORE="0"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)     SOURCE="$2"; shift 2 ;;
        --signal)     SIGNAL="$2"; shift 2 ;;
        --action)     ACTION="$2"; shift 2 ;;
        --gate-score) GATE_SCORE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ ! -f "$WS" ]]; then
    cat > "$WS" << 'EOF'
{"version": 1, "lastBroadcastAt": "", "currentFocus": null,
 "recentBroadcasts": [], "attentionFocus": [], "context": {}}
EOF
fi

# ring buffer of 5 (newest first), then set currentFocus
jq --arg src "$SOURCE" --arg sig "$SIGNAL" --arg action "$ACTION" \
   --argjson gs "${GATE_SCORE:-0}" --arg now "$NOW" \
  '.recentBroadcasts = ([{source: $src, signal: $sig, action: $action,
     gateScore: $gs, at: $now}] + .recentBroadcasts)[0:5]
   | .currentFocus = {source: $src, signal: $sig, action: $action,
     gateScore: $gs, at: $now}
   | .lastBroadcastAt = $now' \
  "$WS" > "$WS.tmp.$$" && mv "$WS.tmp.$$" "$WS"