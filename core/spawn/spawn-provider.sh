#!/bin/bash
# spawn-provider.sh — ROADMAP M3: provider abstraction for daemon spawn jobs.
#
# Dispatches a spawn job's task text to `hermes` (the external harness) OR the
# suite's own local OpenAI-compatible inference (llm-call.sh), selected by
# SPAWN_PROVIDER=hermes|local. The daemon keeps its pidfd/timeout/lock
# machinery intact; this script is the exec boundary, so the pid the daemon
# tracks is the real worker (uses `exec`, never a detached child — a timeout
# SIGKILL therefore reaches the actual hermes/llm-call process).
#
# USAGE:
#   SPAWN_PROVIDER=hermes|local spawn-provider.sh --task '<task text>' [--yolo]
#
# ENV:
#   SPAWN_PROVIDER   hermes (default) | local
#   WORKSPACE        suite workspace (for deployed llm-call.sh resolution)
#   LLM_BASE_URL / LLM_MODEL / LLM_TIMEOUT / LLM_RETRIES
#                    passed through to llm-call.sh in local mode
#
# EXIT: 0 on completion, non-zero on failure. Never daemonizes.
#  2  --task missing           3  hermes requested but not in PATH
#  4  local requested but llm-call.sh not found  5  unknown provider

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROVIDER="${SPAWN_PROVIDER:-hermes}"
TASK=""
YOLO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --yolo) YOLO=true; shift ;;
    *) shift ;;
  esac
done

[ -n "$TASK" ] || { echo "spawn-provider: --task is required" >&2; exit 2; }

case "$PROVIDER" in
  hermes)
    if ! command -v hermes >/dev/null 2>&1; then
      echo "spawn-provider: provider=hermes but hermes not in PATH" >&2
      exit 3
    fi
    if [ "$YOLO" = true ]; then
      exec hermes chat -q "$TASK" --source daemon --accept-hooks --yolo
    else
      exec hermes chat -q "$TASK" --source daemon
    fi
    ;;
  local)
    WS="${WORKSPACE:-$HOME/.hermes/workspace}"
    LLM_CALL=""
    for c in \
        "$ROOT/skills/anterior-cingulate-memory/scripts/llm-call.sh" \
        "$ROOT/skills/prefrontal-cortex-memory/scripts/llm-call.sh" \
        "$WS/skills/anterior-cingulate-memory/scripts/llm-call.sh" \
        "$WS/skills/prefrontal-cortex-memory/scripts/llm-call.sh"; do
      if [ -x "$c" ]; then LLM_CALL="$c"; break; fi
    done
    if [ -z "$LLM_CALL" ]; then
      echo "spawn-provider: provider=local but llm-call.sh not found anywhere" >&2
      exit 4
    fi
    exec bash "$LLM_CALL" \
      --system "You are the daemon agent for the AI Brain Suite. Execute the scheduled spawn job described in the user message. Follow the instructions precisely and report what you did. Be concise." \
      --user "$TASK"
    ;;
  *)
    echo "spawn-provider: unknown SPAWN_PROVIDER '$PROVIDER' (expected hermes|local)" >&2
    exit 5
    ;;
esac
