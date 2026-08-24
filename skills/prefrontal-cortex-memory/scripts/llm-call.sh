#!/bin/bash
# llm-call.sh — Call a local OpenAI-compatible chat completions endpoint.
#
# Works against Ollama (--api-base http://localhost:11434/v1), LM Studio
# (http://localhost:1234/v1), vLLM, or anything else that speaks the
# OpenAI /v1/chat/completions schema. No external API, no cost, no
# rate limits — this is purely local-network curl.
#
# USAGE:
#   llm-call.sh --system '<system prompt>' --user '<user prompt>' [options]
#   echo '<system prompt>' | llm-call.sh --system-stdin --user '<user prompt>' [options]
#
# OPTIONS:
#   --system <text>      System prompt
#   --system-stdin        Read the system prompt from stdin instead (must be
#                          passed explicitly — stdin is never auto-detected)
#   --user <text>        User prompt (required)
#   --base-url <url>     Default: $LLM_BASE_URL or http://localhost:1234/v1
#   --model <name>       Default: $LLM_MODEL or "local-model"
#   --timeout <secs>     Per-attempt curl timeout. Default: $LLM_TIMEOUT or 10
#   --retries <n>        Retry attempts after the first try. Default: $LLM_RETRIES or 2
#   --json                Request JSON-mode output (response_format json_object).
#                          Not all local servers/models honor this — callers
#                          must still validate the response, never trust it blindly.
#
# OUTPUT: the raw assistant message content on stdout. Exit code 0 on
# success, non-zero if every attempt failed (connection refused, timeout,
# malformed response, etc.) — callers MUST handle a non-zero exit and fall
# back to a non-LLM path. This script never assumes the local server is up.
#
# ENV OVERRIDES: LLM_BASE_URL, LLM_MODEL, LLM_TIMEOUT, LLM_RETRIES

set -u

BASE_URL="${LLM_BASE_URL:-http://localhost:1234/v1}"
MODEL="${LLM_MODEL:-local-model}"
TIMEOUT="${LLM_TIMEOUT:-30}"
RETRIES="${LLM_RETRIES:-2}"
SYSTEM_PROMPT=""
USER_PROMPT=""
JSON_MODE=false
READ_SYSTEM_FROM_STDIN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --system) SYSTEM_PROMPT="$2"; shift 2 ;;
    --system-stdin) READ_SYSTEM_FROM_STDIN=true; shift ;;
    --user) USER_PROMPT="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
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
  echo "Usage: llm-call.sh --user '<prompt>' [--system '<prompt>'] [options]" >&2
  exit 2
fi

REQUEST_FILE=$(mktemp)
trap 'rm -f "$REQUEST_FILE"' EXIT

export LC_SYS="$SYSTEM_PROMPT"
export LC_USER="$USER_PROMPT"
export LC_MODEL="$MODEL"

# NOTE: the ENTIRE right-hand side of "messages: (...)" must be wrapped in one
# outer paren group, including the trailing `+ [...]`. Wrapping only the
# piped sub-expression (`[...] | if ... end`) and leaving the `+` outside is
# a jq syntax error — object-value expressions containing a top-level `|`
# need the whole expression parenthesized, not just the piped part.
if [ "$JSON_MODE" = true ]; then
  jq -n --arg model "$LC_MODEL" --arg sys "$LC_SYS" --arg user "$LC_USER" \
    '{model: $model, messages: (([{role:"system", content:$sys}] | if $sys == "" then [] else . end) + [{role:"user", content:$user}]), temperature: 0.3, response_format: {type: "json_object"}}' \
    > "$REQUEST_FILE"
else
  jq -n --arg model "$LC_MODEL" --arg sys "$LC_SYS" --arg user "$LC_USER" \
    '{model: $model, messages: (([{role:"system", content:$sys}] | if $sys == "" then [] else . end) + [{role:"user", content:$user}]), temperature: 0.3}' \
    > "$REQUEST_FILE"
fi

ATTEMPT=0
MAX_ATTEMPTS=$((RETRIES + 1))

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
  ATTEMPT=$((ATTEMPT + 1))

  RESPONSE=$(curl -s -S --max-time "$TIMEOUT" \
    -X POST "$BASE_URL/chat/completions" \
    -H "Content-Type: application/json" \
    -d @"$REQUEST_FILE" 2>/tmp/llm-call-err.$$)
  CURL_STATUS=$?

  if [ "$CURL_STATUS" -eq 0 ] && [ -n "$RESPONSE" ]; then
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)

    # Thinking models (Qwen, DeepSeek, etc.) may put the actual reply in
    # reasoning_content and leave content empty — fall back to it.
    if [ -z "$CONTENT" ]; then
      CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.reasoning_content // empty' 2>/dev/null)
    fi

    if [ -n "$CONTENT" ]; then
      printf '%s' "$CONTENT"
      rm -f /tmp/llm-call-err.$$
      exit 0
    fi

    if [ -n "$ERROR_MSG" ]; then
      echo "⚠️  llm-call.sh: server returned an error: $ERROR_MSG" >&2
    else
      echo "⚠️  llm-call.sh: response had no .choices[0].message.content or reasoning_content (attempt $ATTEMPT/$MAX_ATTEMPTS)" >&2
    fi
  else
    echo "⚠️  llm-call.sh: curl failed (exit $CURL_STATUS, attempt $ATTEMPT/$MAX_ATTEMPTS): $(cat /tmp/llm-call-err.$$ 2>/dev/null)" >&2
  fi

  rm -f /tmp/llm-call-err.$$
  [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ] && sleep 1
done

echo "❌ llm-call.sh: all $MAX_ATTEMPTS attempt(s) failed against $BASE_URL" >&2
exit 1
