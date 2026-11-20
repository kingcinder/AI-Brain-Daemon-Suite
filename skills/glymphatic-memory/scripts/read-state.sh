#!/bin/bash
# Glymphatic: Load state (reader)
# Shows clearance state and stamps lastConsultedAt.

set -e

WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
STATE_FILE="$WORKSPACE/memory/glymphatic-state.json"
STATE_MD="$WORKSPACE/GLYMPHATIC_STATE.md"

if [ ! -f "$STATE_FILE" ]; then
    echo "🌊 Glymphatic: No state file yet (fresh start)"
    exit 0
fi

if [ ! -f "$STATE_MD" ]; then
    echo "🌊 Glymphatic: State exists but no GLYMPHATIC_STATE.md — run sync-state.sh"
    exit 0
fi

echo "🌊 Glymphatic State Loaded:"
echo ""
cat "$STATE_MD"

# Best-effort staleness tracking: record that this state was actually
# read, separate from lastUpdated (write path). Never blocks output.
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
