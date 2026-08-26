#!/bin/bash
# decay.sh — Release suppressed signals from the retry queue that have aged
# past their retryAfter window. Suppressed signals aren't dropped permanently —
# they're deferred and re-evaluated in the next cycle. This ensures important
# signals that were suppressed due to high load / low circadian gain still
# eventually get processed.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/thalamus-state.json"

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SIGNAL_LOG="$WORKSPACE/memory/brain-signals.jsonl"

# Serialize against gate.sh (also a writer of thalamus-state.json) so this
# read-modify-write can't lose a signal the gate just suppressed.
exec 200>"$STATE_FILE.lock"
flock 200

# Signals whose retryAfter has passed are NOT dropped — they are re-injected
# into the signal bus so the next gate run re-scores them (the header's
# "deferred and re-evaluated in the next cycle" contract). Only still-pending
# signals (retryAfter > now) remain in the suppressed queue.
DUE=$(jq -c --arg now "$NOW" \
  '[.suppressedQueue[] | select(.retryAfter <= $now) | {
     source: .signal.source, signal: .signal.signal, intensity: .intensity,
     suppressedAt: .suppressedAt }]' "$STATE_FILE" 2>/dev/null || echo "[]")

if [ "$DUE" != "[]" ]; then
  mkdir -p "$(dirname "$SIGNAL_LOG")"
  printf '%s' "$DUE" | jq -c '.[]' | while IFS= read -r item; do
    [ -z "$item" ] && continue
    src=$(printf '%s' "$item" | jq -r '.source // ""')
    sig=$(printf '%s' "$item" | jq -r '.signal // ""')
    int=$(printf '%s' "$item" | jq -r '.intensity // 0.5')
    [ -z "$src" ] && continue
    jq -nc --arg ts "$NOW" --arg src "$src" --arg sig "$sig" --argjson int "$int" \
      '{ts:$ts, type:"thalamus_retry", source:$src, signal:$sig, intensity:$int,
        payload:{retried:true, reason:"retryAfter elapsed (thalamus decay)"}}' \
      >> "$SIGNAL_LOG" 2>/dev/null || true
  done
fi

# Update the queue: keep only still-pending signals (atomic tmp+mv under lock)
tmp="$STATE_FILE.tmp.$$"
jq --arg now "$NOW" \
  '.suppressedQueue = [.suppressedQueue[] | select(.retryAfter > $now)]' \
  "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE"

# Count remaining
remaining=$(jq -r '.suppressedQueue | length' "$STATE_FILE" 2>/dev/null || echo "0")
echo "🚦 Thalamus decay: $remaining signals remain in suppressed queue"

exit 0
