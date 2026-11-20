#!/bin/bash
# Claustrum: Load state (reader)
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
STATE_FILE="$WORKSPACE/memory/claustrum-state.json"
STATE_MD="$WORKSPACE/CORTICAL_STATE.md"
if [ ! -f "$STATE_FILE" ]; then
    echo "🧩 Claustrum: No state file yet (fresh start)"
    exit 0
fi
if [ ! -f "$STATE_MD" ]; then
    echo "🧩 Claustrum: State exists but no CORTICAL_STATE.md — run sync-state.sh"
    exit 0
fi
echo "🧩 Claustrum State Loaded:"
echo ""
cat "$STATE_MD"
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
