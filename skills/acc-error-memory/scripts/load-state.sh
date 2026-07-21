#!/bin/bash
# ACC: Load state at session start
# Shows current error patterns and lessons learned

set -e

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/acc-state.json"
STATE_MD="$WORKSPACE/ACC_STATE.md"

# Check if state file exists
if [ ! -f "$STATE_FILE" ]; then
    echo "⚡ ACC: No state file yet (fresh start)"
    exit 0
fi

# Check if markdown state exists
if [ ! -f "$STATE_MD" ]; then
    echo "⚡ ACC: State exists but no ACC_STATE.md — run sync-state.sh"
    exit 0
fi

# Output the markdown state for context
echo "⚡ ACC State Loaded:"
echo ""
cat "$STATE_MD"

# Best-effort staleness tracking: record that this state was actually read,
# separate from lastUpdated (write path). Never blocks or fails the output above.
exec 200>"$STATE_FILE.lock"
flock 200
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
