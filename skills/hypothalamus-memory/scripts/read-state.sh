#!/bin/bash
# Hypothalamus: Load state (reader)
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
STATE_FILE="$WORKSPACE/memory/hypothalamus-state.json"
STATE_MD="$WORKSPACE/HYPOTHALAMUS_STATE.md"
if [ ! -f "$STATE_FILE" ]; then
    echo "🌡️ Hypothalamus: No state file yet (fresh start)"
    exit 0
fi
if [ ! -f "$STATE_MD" ]; then
    echo "🌡️ Hypothalamus: State exists but no HYPOTHALAMUS_STATE.md — run sync-state.sh"
    exit 0
fi
echo "🌡️ Hypothalamus State Loaded:"
echo ""
cat "$STATE_MD"
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
