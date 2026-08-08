#!/bin/bash
# decay.sh — Release suppressed signals from the retry queue that have aged
# past their retryAfter window. Suppressed signals aren't dropped permanently —
# they're deferred and re-evaluated in the next cycle. This ensures important
# signals that were suppressed due to high load / low circadian gain still
# eventually get processed.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"
SIGNAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Release signals whose retryAfter has passed
tmp="$STATE_FILE.tmp"
jq --arg now "$NOW" '
.suppressedQueue = [
    .suppressedQueue[] |
    select(.retryAfter > $now)
]' "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE"

# Count released
remaining=$(jq -r '.suppressedQueue | length' "$STATE_FILE" 2>/dev/null || echo "0")
echo "🚦 Thalamus decay: $remaining signals remain in suppressed queue"

exit 0
