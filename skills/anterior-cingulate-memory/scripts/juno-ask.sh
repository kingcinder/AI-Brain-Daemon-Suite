#!/bin/bash
# juno-ask.sh — Ask Juno directly, through the helm queue.
#
# Juno herself is the reasoning backend of this suite. There is no model
# server on this host and none may be started (the model-serving moratorium
# is standing); this script enqueues the request for a Juno agent turn via
# the openclaw shim (juno:enqueue), Juno answers through the results
# channel (drain:respond), and this script prints her response.
#
# USAGE:
#   juno-ask.sh --system '<system prompt>' --user '<user prompt>' [options]
#   echo '<system prompt>' | juno-ask.sh --system-stdin --user '<user prompt>' [options]
#
# OPTIONS:
#   --system <text>      System prompt
#   --system-stdin       Read the system prompt from stdin instead (must be
#                        passed explicitly — stdin is never auto-detected)
#   --user <text>        User prompt (required)
#   --timeout <secs>     Queue wait bound per attempt. Default: $JUNO_TIMEOUT or 60
#   --retries <n>        Re-enqueue attempts after the first try. Default: $JUNO_RETRIES or 0
#   --json               Ask Juno for JSON-mode output. Callers must still
#                        validate the response, never trust it blindly.
#
# OUTPUT: Juno's response text on stdout. Exit code 0 on success, non-zero
# if no answer arrived within the bound — callers MUST handle a non-zero
# exit and fall back to a non-Juno path. This script never assumes Juno
# will answer within the wait.
#
# ENV OVERRIDES: JUNO_TIMEOUT, JUNO_RETRIES, JUNO_QUEUE_WAIT (alias of the
# wait bound), JUNO_LABEL

set -u

TIMEOUT="${JUNO_TIMEOUT:-${JUNO_QUEUE_WAIT:-60}}"
RETRIES="${JUNO_RETRIES:-0}"
SYSTEM_PROMPT=""
USER_PROMPT=""
JSON_MODE=false
READ_SYSTEM_FROM_STDIN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --system) SYSTEM_PROMPT="$2"; shift 2 ;;
    --system-stdin) READ_SYSTEM_FROM_STDIN=true; shift ;;
    --user) USER_PROMPT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --json) JSON_MODE=true; shift ;;
    *) shift ;;
  esac
done

# Only read from stdin if explicitly requested via --system-stdin. Auto-detecting
# "is stdin piped" via [ ! -t 0 ] is NOT safe here: plenty of non-interactive
# callers (cron, some agent/tool harnesses) leave stdin open but never write to
# or close it, which makes a bare `cat` block indefinitely with no way out.
if [ "$READ_SYSTEM_FROM_STDIN" = true ]; then
  SYSTEM_PROMPT="$(cat)"
fi

if [ -z "$USER_PROMPT" ]; then
  echo "Usage: juno-ask.sh --user '<prompt>' [--system '<prompt>'] [options]" >&2
  exit 2
fi

# ── Helm queue: the only path ─────────────────────────────────────────────
# The request is enqueued for a Juno agent turn: the shim (openclaw)
# appends it to the suite queue as type "juno", Juno answers through the
# results channel, and this script prints her response. The wait is
# BOUNDED by --timeout / JUNO_QUEUE_WAIT (default 60s): on timeout, or if
# the queue is unavailable, the script exits 1 and the caller's existing
# fallback engages — a job never hangs waiting for a drain.
OC_BIN="$(command -v openclaw 2>/dev/null || echo "$HOME/.local/bin/openclaw")"
WS_DIR="${BRAIN_WORKSPACE:-${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.juno-brain/workspace}}}"

if [ ! -x "$OC_BIN" ] || [ ! -d "$WS_DIR/memory" ]; then
  echo "❌ juno-ask.sh: helm queue unavailable (shim or workspace missing) — caller's fallback engages" >&2
  exit 1
fi

REQ_JSON=$(jq -n --arg sys "$SYSTEM_PROMPT" --arg user "$USER_PROMPT" \
  --argjson json "$JSON_MODE" --arg label "${JUNO_LABEL:-juno-ask}" \
  '{system: $sys, user: $user, json: $json, label: $label}')

ATTEMPT=0
while [ "$ATTEMPT" -le "$RETRIES" ]; do
  QID=$(printf '%s' "$REQ_JSON" | WORKSPACE="$WS_DIR" BRAIN_WORKSPACE="$WS_DIR" "$OC_BIN" juno:enqueue 2>/dev/null)
  if [ -n "$QID" ]; then
    WAITED=0
    while [ "$WAITED" -lt "$TIMEOUT" ]; do
      OUT=$(WORKSPACE="$WS_DIR" BRAIN_WORKSPACE="$WS_DIR" "$OC_BIN" juno:result "$QID" 2>/dev/null)
      QRC=$?
      if [ "$QRC" -eq 0 ]; then
        printf '%s' "$OUT"
        exit 0
      fi
      [ "$QRC" -eq 4 ] && break
      sleep 3
      WAITED=$((WAITED + 3))
    done
    echo "⚠️  juno-ask.sh: helm queue produced no answer within ${TIMEOUT}s ($QID)" >&2
  fi
  ATTEMPT=$((ATTEMPT + 1))
done

echo "❌ juno-ask.sh: no answer from Juno via the helm queue — caller's fallback engages" >&2
exit 1
