#!/bin/bash
# agent-loop.sh — Juno's internal agentic loop (AUDIT Gap 2 follow-on).
#
# Juno's own multi-turn tool-use loop: it runs a task by asking Juno
# directly (through the helm queue, via juno-ask.sh), executing allowlisted
# suite tools (core/agent-loop/tools.sh) and carrying session memory across
# turns (and across invocations, when the same session id is reused) — a
# spawn job reasons and acts as Juno herself, with no other seat involved.
#
# Turn protocol (Juno replies in JSON mode):
#   {"tool": "<allowlisted-name>", "args": {...}}   → execute, append result, loop
#   {"answer": "<final text>"}                       → append, print, exit 0
# Anything else → one corrective re-prompt, then honest failure.
#
# Honest-failure contract (same as juno-ask.sh): if Juno cannot be reached
# through the helm queue, the loop exits non-zero so the daemon records a
# job failure, never a silent skip. Tool output is truncated (~1200 chars)
# and the transcript capped (task pinned at line 1 + last 7 turns) — the
# task can never be evicted mid-run.
#
# USAGE:
#   agent-loop.sh --task '<task text>' [--session-id ID] [--max-steps N]
#
# ENV: WORKSPACE, JUNO_TIMEOUT / JUNO_RETRIES
#   (passed through to juno-ask.sh; defaults as juno-ask.sh's)
#   AGENT_STUB_JUNO  path to a stub responder script for tests (the only way
#                    to make the loop deterministic without a Juno turn)
#
# EXIT: 0 on completion (answer reached), 1 on Juno/tool failure, 2 on usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_ROOT="${AGENT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
TASK=""
SESSION_ID=""
MAX_STEPS=8
OUT_CAP=1200
TRANSCRIPT_CAP=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --max-steps) MAX_STEPS="${2:-5}"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$TASK" ] || { echo "agent-loop: --task is required" >&2; exit 2; }

# ── Resolve juno-ask.sh, the Juno caller (same search pattern as spawn-provider) ──
JUNO_ASK=""
for c in \
    "$AGENT_ROOT/skills/anterior-cingulate-memory/scripts/juno-ask.sh" \
    "$AGENT_ROOT/skills/prefrontal-cortex-memory/scripts/juno-ask.sh" \
    "$WORKSPACE/skills/anterior-cingulate-memory/scripts/juno-ask.sh" \
    "$WORKSPACE/skills/prefrontal-cortex-memory/scripts/juno-ask.sh"; do
  if [ -x "$c" ]; then JUNO_ASK="$c"; break; fi
done
if [ -z "$JUNO_ASK" ] && [ -z "${AGENT_STUB_JUNO:-}" ]; then
  echo "agent-loop: juno-ask.sh not found anywhere (and no AGENT_STUB_JUNO for tests)" >&2
  exit 4
fi

# ── Session memory ───────────────────────────────────────────────────────────
# AGENT_SESSION_ID (set by the daemon's run_spawn for juno jobs) gives a
# recurring spawn job a STABLE session id derived from its job name, so it
# remembers its prior turns across scheduled runs — not just within one run.
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${AGENT_SESSION_ID:-spawn-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
fi
SESSION_DIR="$WORKSPACE/memory/agent-sessions"
SESSION_FILE="$SESSION_DIR/${SESSION_ID}.jsonl"
mkdir -p "$SESSION_DIR"
touch "$SESSION_FILE"

# ── Tool registry ────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$SCRIPT_DIR/tools.sh"

append_turn() {
  # append_turn <role> <json-payload>
  local role="$1" payload="$2"
  printf '%s\n' "$(jq -nc --arg role "$role" --argjson payload "$payload" '{role:$role, payload:$payload, ts:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}')" >> "$SESSION_FILE"
  # Pin the task: the newest "user" (task) turn is moved to line 1 so a long
  # agentic run — or a reused session (stable AGENT_SESSION_ID) — can never
  # lose its task context to the rolling cap. On reuse the new task replaces
  # the old pinned one; the old task stays in history like any prior turn.
  if [ "$role" = "user" ]; then
    tail -n 1 "$SESSION_FILE" > "$SESSION_FILE.tmp"
    sed '$d' "$SESSION_FILE" >> "$SESSION_FILE.tmp"
    mv "$SESSION_FILE.tmp" "$SESSION_FILE"
  fi
  # Cap transcript: keep the pinned task (line 1) + last (CAP-1) turn lines.
  # temp+mv makes each write atomic — a torn write can only drop old turns,
  # never corrupt the JSONL (session memory is shared state once stable ids
  # are in play, even though the daemon's spawn lock serializes most access).
  if [ "$(wc -l < "$SESSION_FILE")" -gt "$TRANSCRIPT_CAP" ]; then
    head -n 1 "$SESSION_FILE" > "$SESSION_FILE.tmp"
    tail -n "$((TRANSCRIPT_CAP - 1))" "$SESSION_FILE" >> "$SESSION_FILE.tmp"
    mv "$SESSION_FILE.tmp" "$SESSION_FILE"
  fi
}

transcript_json() {
  # Reconstruct the visible transcript as a JSON array of {role, content}
  # strings for Juno's prompt (tool results are short by construction).
  python3 - "$SESSION_FILE" << 'PY'
import json, sys
from pathlib import Path
out = []
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.strip():
        continue
    try:
        e = json.loads(line)
    except ValueError:
        continue
    p = e.get("payload") or {}
    role = e.get("role")
    if role == "user":
        out.append({"role": "user", "content": p.get("task", "")})
    elif role == "tool":
        out.append({"role": "user", "content": "[tool result] " + json.dumps(p, ensure_ascii=False)[:800]})
    elif role == "assistant":
        if p.get("answer"):
            out.append({"role": "assistant", "content": "[answer] " + p["answer"]})
        elif p.get("tool"):
            out.append({"role": "assistant", "content": "[tool call] " + p["tool"] + " " + json.dumps(p.get("args") or {}, ensure_ascii=False)})
print(json.dumps(out))
PY
}

call_juno() {
  # call_juno <system-prompt> <transcript-json> → Juno's raw reply (stdout)
  # Runs inside a command-substitution subshell, so it must NOT mutate parent
  # state — the caller increments TURN_COUNT and passes it via AGENT_TURN for
  # the stub responder (see the while loop below).
  local sys_p="$1" transcript="$2"
  if [ -n "${AGENT_STUB_JUNO:-}" ]; then
    AGENT_TURN="$TURN_COUNT" bash "$AGENT_STUB_JUNO"
    return
  fi
  bash "$JUNO_ASK" --json --system "$sys_p" --user "$transcript"
}

SYSTEM_PROMPT=$(cat << 'PROMPT'
You are Juno, the AI Brain Suite's own agent. You are given a task and a
running transcript. Use ONLY the tools listed below — there is no bash,
shell, or command-line access. To run scripts, use the run_suite_script
tool. To execute code, gather info, or do any work, use the tools below.
Finish with an {"answer": ...} — a concise report of what you did.
PROMPT
)
SYSTEM_PROMPT="$SYSTEM_PROMPT

$(agent_tool_descriptions)"

# ── Seed the session with the task ───────────────────────────────────────────
append_turn "user" "$(jq -nc --arg task "$TASK" '{task:$task}')"

TURN_COUNT=0
STEP=0
RESULT=""
while [ "$STEP" -lt "$MAX_STEPS" ]; do
  STEP=$((STEP + 1))
  # Increment here (parent scope), NOT inside call_juno — command substitution
  # runs in a subshell where the increment would be lost (the stub would see
  # AGENT_TURN=1 every turn and the loop could never progress to an answer).
  TURN_COUNT=$((TURN_COUNT + 1))
  TRANSCRIPT=$(transcript_json)

  # ── Ask Juno ──────────────────────────────────────────────────────────
  RAW=""
  if ! RAW=$(call_juno "$SYSTEM_PROMPT" "$TRANSCRIPT" 2>"$WORKSPACE/memory/agent-loop.err"); then
    echo "agent-loop: asking Juno failed on step $STEP (see memory/agent-loop.err)" >&2
    exit 1
  fi
  [ -n "$RAW" ] || { echo "agent-loop: empty reply from Juno on step $STEP" >&2; exit 1; }

  # ── Parse: strip fences, then require exactly one of tool | answer ───────
  CLEANED=$(printf '%s' "$RAW" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
  KIND=$(printf '%s' "$CLEANED" | jq -r 'if has("answer") then "answer" elif has("tool") then "tool" else "invalid" end' 2>/dev/null || echo "invalid")

  # Fallback: if jq failed (e.g. trailing garbage after the JSON object),
  # extract the first complete JSON object by bracket-matching.
  if [ "$KIND" = "invalid" ]; then
    # Find the first '{' and extract the balanced object after it.
    FIRST_OBJ=$(printf '%s' "$CLEANED" | awk '
      BEGIN { depth=0; in_obj=0; buf="" }
      {
        for (i=1; i<=length($0); i++) {
          c = substr($0, i, 1)
          if (!in_obj) {
            if (c == "{") { in_obj=1; depth=1; buf=c }
            continue
          }
          buf = buf c
          if (c == "{") depth++
          if (c == "}") {
            depth--
            if (depth == 0) { print buf; exit }
          }
        }
      }
    ')
    if [ -n "$FIRST_OBJ" ]; then
      KIND=$(printf '%s' "$FIRST_OBJ" | jq -r 'if has("answer") then "answer" elif has("tool") then "tool" else "invalid" end' 2>/dev/null || echo "invalid")
      if [ "$KIND" != "invalid" ]; then
        CLEANED="$FIRST_OBJ"
      fi
    fi
  fi

  if [ "$KIND" = "answer" ]; then
    ANSWER=$(printf '%s' "$CLEANED" | jq -r '.answer // ""')
    append_turn "assistant" "$(jq -nc --arg a "$ANSWER" '{answer:$a}')"
    RESULT="$ANSWER"
    break
  fi

  if [ "$KIND" = "tool" ]; then
    TOOL=$(printf '%s' "$CLEANED" | jq -r '.tool // ""')
    ARGS=$(printf '%s' "$CLEANED" | jq -c '.args // {}')
    # Allowlist check: the registry rejects unknown tools with a payload; the
    # loop records the rejection and lets Juno correct course.
    if ! printf '%s\n' "$AGENT_TOOL_NAMES" | grep -qw "$TOOL"; then
      OUT=$(agent_tool_reject "$TOOL" "unknown tool")
    else
      OUT=$(agent_tool_run "$TOOL" "$ARGS" 2>/dev/null || echo '{"tool_error":"execution failed"}')
    fi
    # Truncate long tool output to the cap.
    OUT_TRUNC=$(printf '%s' "$OUT" | head -c "$OUT_CAP")
    append_turn "tool" "$(jq -nc --arg tool "$TOOL" --arg out "$OUT_TRUNC" '{tool:$tool, result:$out}')"
    continue
  fi

  # Invalid reply: one corrective re-prompt, then honest failure.
  if [ "$STEP" -ge "$MAX_STEPS" ]; then
    echo "agent-loop: Juno never produced a valid tool/answer reply (step $STEP)" >&2
    exit 1
  fi
  append_turn "tool" "$(jq -nc '{tool:"__validator__", result:"Invalid reply — respond with exactly one JSON object: either {\"tool\":\"<name>\",\"args\":{...}} or {\"answer\":\"<text>\"}."}')"
done

if [ -z "$RESULT" ] && [ "$STEP" -ge "$MAX_STEPS" ]; then
  echo "agent-loop: reached --max-steps $MAX_STEPS without an answer" >&2
  exit 1
fi

printf '%s\n' "$RESULT"
exit 0
