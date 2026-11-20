#!/bin/bash
# spawn-provider.sh — ROADMAP M3, Juno-direct (2026-11-20 scrub): the sole
# spawn provider is Juno herself.
#
# Dispatches a spawn job's task text to Juno's internal agentic loop
# (core/agent-loop/agent-loop.sh — tool use + session memory), which asks
# Juno through the helm queue (juno-ask.sh). There is no other provider:
# no external harness and no model server exists in this suite. The daemon
# keeps its pidfd/timeout/lock machinery intact; this script is the exec
# boundary, so the pid the daemon tracks is the real worker (uses `exec`,
# never a detached child — a timeout SIGKILL therefore reaches the actual
# worker process).
#
# USAGE:
#   SPAWN_PROVIDER=juno spawn-provider.sh --task '<task text>' [--yolo]
#   (--yolo is accepted for daemon call compatibility and ignored: Juno's
#   loop has no approval gate to bypass.)
#
# ENV:
#   SPAWN_PROVIDER   juno (default, and the only provider)
#   WORKSPACE        suite workspace
#   AGENT_STUB_JUNO  stub responder for deterministic tests (loop tests)
#   AGENT_MAX_STEPS  per-job step budget for the loop
#   AGENT_DIRECT_REPLY  when 1, append a direct-reply instruction so Juno's
#                    loop turns answer with a tool call or a final answer
#                    immediately, in the loop's JSON protocol
#
# EXIT: 0 on completion, non-zero on failure. Never daemonizes.
#  2  --task missing           5  unknown provider
#  6  Juno loop (agent-loop.sh) not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROVIDER="${SPAWN_PROVIDER:-juno}"
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
  juno)
    # Juno's internal agentic loop — tool use + session memory, asking Juno
    # via the helm queue. `exec` keeps the tracked pid the real worker.
    LOOP="$ROOT/core/agent-loop/agent-loop.sh"
    if [ ! -f "$LOOP" ]; then
      echo "spawn-provider: provider=juno but core/agent-loop/agent-loop.sh not found" >&2
      exit 6
    fi
    # Per-job step budget: AGENT_MAX_STEPS overrides the loop's default
    # (set by deep-brain-kernel.py from job.spawn_max_steps).
    STEPS="${AGENT_MAX_STEPS:-8}"
    # Direct-reply instruction: when AGENT_DIRECT_REPLY=1, append a suffix
    # asking Juno to respond immediately with a tool call (using
    # run_suite_script) or a final answer, in the loop's JSON protocol.
    EFFECTIVE_TASK="$TASK"
    if [ "${AGENT_DIRECT_REPLY:-0}" = "1" ]; then
      EFFECTIVE_TASK=$(printf '%s\n\nIMPORTANT: Respond immediately with a tool call (using run_suite_script) or a final answer. Keep your response concise.' "$TASK")
    fi
    # The loop resolves juno-ask.sh itself (its own exit 4 covers a missing
    # Juno caller) and honors AGENT_STUB_JUNO for deterministic tests.
    exec bash "$LOOP" --task "$EFFECTIVE_TASK" --max-steps "$STEPS"
    ;;
  *)
    echo "spawn-provider: unknown SPAWN_PROVIDER '$PROVIDER' (expected juno — Juno is the only provider)" >&2
    exit 5
    ;;
esac
