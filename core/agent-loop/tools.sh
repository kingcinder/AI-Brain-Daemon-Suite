#!/bin/bash
# tools.sh — Allowlisted tool registry for the internal agentic loop.
#
# The agent loop (agent-loop.sh) can ONLY execute tools declared here. This
# is a fixed, curated allowlist of suite operations — the model proposes a
# tool name + JSON args, the registry maps name → a fixed command with
# jq-extracted arguments. Nothing is ever eval'd; an unknown tool name is a
# rejected call, never an arbitrary command.
#
# USAGE (source this from the loop driver):
#   agent_tool_run <name> '<json-args>'
#     → executes the tool, prints its output to stdout, exit 0 on success
#       (output is captured/truncated by the caller)
#   agent_tool_list
#     → prints the tool descriptions for the system prompt
#   agent_tool_reject <name> '<reason>'
#     → prints a tool-error payload (used for unknown/blocked tools)
#
# ENV: WORKSPACE, AGENT_ROOT (suite root — resolved by the caller)

set -euo pipefail

AGENT_TOOL_NAMES="get_goals get_lessons get_conflict_state get_heartbeat get_verification_report list_memory_state record_goal_outcome run_suite_script"

agent_tool_descriptions() {
  cat << 'TOOLS'
Available tools (reply with ONE tool call per turn, JSON: {"tool":"<name>","args":{...}}, or finish with {"answer":"<text>"}):
- get_goals                args: {}            List active PFC goals (description, priority, status)
- get_lessons              args: {}            Retrieve resolved error-pattern lessons from acc-error memory
- get_conflict_state       args: {}            Read anterior-cingulate conflict load + active conflicts
- get_heartbeat            args: {}            Read daemon heartbeat state (last beat, beat count, chosen action)
- get_verification_report  args: {}            Most recent verification sweep: totals + failing modules
- list_memory_state        args: {}            List memory/*.json state files with sizes (what exists)
- record_goal_outcome      args: {"goal":"<desc>","outcome":"success|failure"}  Record a goal outcome to PFC state
- run_suite_script         args: {"script":"<relative-path>","args":[...]}  Run a suite script (encode-pipeline.sh, preprocess-*.sh, sync-state.sh, sync-core.sh, update-watermark.sh, etc.). Script must be under skills/<skill>/scripts/ in the workspace.
Rules: call at most one tool per turn. Never invent tools. Finish with an {"answer":...} only when the task is done.
TOOLS
}

agent_tool_run() {
  local name="$1" args="$2"
  local jq_extract
  case "$name" in
    get_goals)
      if [ -f "${WORKSPACE:-}/memory/pfc-state.json" ]; then
        jq -c '{active: [.goals[]? | select(.status=="active") | {description, priority, status}]}' "$WORKSPACE/memory/pfc-state.json" 2>/dev/null \
          || echo '{"error":"pfc-state unreadable"}'
      else
        echo '{"goals":[],"note":"no pfc-state.json yet"}'
      fi
      ;;
    get_lessons)
      if [ -x "$AGENT_ROOT/skills/acc-error-memory/scripts/get-lessons.sh" ]; then
        WORKSPACE="${WORKSPACE:-}" bash "$AGENT_ROOT/skills/acc-error-memory/scripts/get-lessons.sh" --json 2>/dev/null \
          || echo '{"lessons":[],"note":"no lessons yet"}'
      else
        echo '{"lessons":[],"note":"get-lessons.sh not found"}'
      fi
      ;;
    get_conflict_state)
      if [ -f "${WORKSPACE:-}/memory/conflict-state.json" ]; then
        jq -c '{conflictLoad, active: (.activeConflicts | length), flags: (.attentionFlags | length)}' "$WORKSPACE/memory/conflict-state.json" 2>/dev/null \
          || echo '{"error":"conflict-state unreadable"}'
      else
        echo '{"conflictLoad":0,"active":0,"flags":0,"note":"no conflict-state.json yet"}'
      fi
      ;;
    get_heartbeat)
      if [ -f "${WORKSPACE:-}/memory/heartbeat-state.json" ]; then
        jq -c '{lastBeat, beatCount, lastChosenAction, lastChosenAt}' "$WORKSPACE/memory/heartbeat-state.json" 2>/dev/null \
          || echo '{"error":"heartbeat-state unreadable"}'
      else
        echo '{"heartbeat":"none"}'
      fi
      ;;
    get_verification_report)
      local report="${WORKSPACE:-}/memory/verification-report.jsonl"
      if [ -f "$report" ]; then
        tail -1 "$report" 2>/dev/null | jq -c '{ts, filter, totals, failures}' 2>/dev/null \
          || echo '{"note":"no sweep recorded yet"}'
      else
        echo '{"note":"no verification report yet"}'
      fi
      ;;
    list_memory_state)
      if [ -d "${WORKSPACE:-}/memory" ]; then
        find "$WORKSPACE/memory" -maxdepth 1 -name '*.json' -printf '%f %s bytes\n' 2>/dev/null | sort || true
      else
        echo '{"note":"no memory dir yet"}'
      fi
      ;;
    record_goal_outcome)
      # args: {"goal":"<desc>","outcome":"success|failure"}
      jq_extract=$(printf '%s' "$args" | jq -r '{goal: (.goal // ""), outcome: (.outcome // "success")}' 2>/dev/null) || {
        echo '{"error":"bad args"}'; return 0; }
      local goal outcome
      goal=$(printf '%s' "$jq_extract" | jq -r '.goal')
      outcome=$(printf '%s' "$jq_extract" | jq -r '.outcome')
      if [ -z "$goal" ] || { [ "$outcome" != "success" ] && [ "$outcome" != "failure" ]; }; then
        echo '{"error":"record_goal_outcome requires goal + outcome in {success,failure}"}'
        return 0
      fi
      if [ -x "$AGENT_ROOT/core/executive/record-goal-outcome.sh" ]; then
        # The recorder's CLI contract is: outcome --goal-description <desc>
        # --outcome success|failure. The old --goal/--outcome shape made the
        # tool fail on every call (usage exit).
        WORKSPACE="${WORKSPACE:-}" bash "$AGENT_ROOT/core/executive/record-goal-outcome.sh" \
          outcome --goal-description "$goal" --outcome "$outcome" 2>/dev/null && echo "{\"recorded\":\"$outcome\",\"goal\":$(printf '%s' "$goal" | jq -Rs .)}" \
          || echo '{"error":"record-goal-outcome failed"}'
      else
        echo '{"error":"record-goal-outcome.sh not found"}'
      fi
      ;;
    run_suite_script)
      # args: {"script":"skills/<skill>/scripts/<name>.sh", "args":["--flag","value"]}
      # Security: only scripts under skills/*/scripts/ with basenames in the allowlist.
      local script_path script_args
      script_path=$(printf '%s' "$args" | jq -r '.script // ""' 2>/dev/null || echo "")
      [ -z "$script_path" ] && { echo '{"tool_error":"run_suite_script","reason":"script path required"}'; return 0; }

      # Reject path traversal
      case "$script_path" in
        *..*|*//*) echo '{"tool_error":"run_suite_script","reason":"invalid path"}'; return 0 ;;
      esac

      # Resolve relative to WORKSPACE if not absolute
      local resolved ws
      ws="${WORKSPACE:-$HOME/.hermes/workspace}"
      if [[ "$script_path" = /* ]]; then
        resolved="$script_path"
      elif [[ "$script_path" == */* ]]; then
        resolved="$ws/$script_path"
      else
        # Bare name (e.g. "encode-pipeline.sh") — search skills/*/scripts/
        resolved=$(find "$ws/skills" -path "*/scripts/$script_path" -type f 2>/dev/null | head -1)
        if [ -z "$resolved" ]; then
          echo "{\"tool_error\":\"run_suite_script\",\"reason\":\"script '$script_path' not found under skills/*/scripts/\"}"; return 0
        fi
      fi

      # Must live under skills/*/scripts/ (deployed workspace layout)
      if [[ "$resolved" != */skills/*/scripts/* ]]; then
        echo '{"tool_error":"run_suite_script","reason":"path must be under skills/<skill>/scripts/"}'; return 0
      fi

      # Allowlist check on basename
      local bname
      bname=$(basename "$resolved")
      case "$bname" in
        encode-pipeline.sh|preprocess-*.sh|sync-state.sh|sync-core.sh|update-watermark.sh|update-state.sh|consolidate.sh|reflect.sh|summarize-pending.sh|log-event.sh|load-*.sh|analyze-day.sh|refine.sh) ;;
        *) echo "{\"tool_error\":\"run_suite_script\",\"reason\":\"script '$bname' not in allowlist\"}"; return 0 ;;
      esac

      if [ ! -f "$resolved" ]; then
        echo "{\"tool_error\":\"run_suite_script\",\"reason\":\"script not found: $bname\"}"; return 0
      fi
      if [ ! -x "$resolved" ]; then
        echo "{\"tool_error\":\"run_suite_script\",\"reason\":\"script not executable: $bname\"}"; return 0
      fi

      # Build args array from JSON (safely: only alphanumeric, dashes, dots, slashes, equals, colons — no shell injection)
      local -a script_args=()
      local argval
      while IFS= read -r argval; do
        [[ -z "$argval" ]] && continue
        # Validate: only safe characters (no spaces, no quotes, no shell metacharacters)
        if [[ "$argval" =~ ^[A-Za-z0-9_./=:-]+$ ]]; then
          script_args+=("$argval")
        fi
      done < <(printf '%s' "$args" | jq -r '.args[]? // empty' 2>/dev/null)

      # Execute: capture output, return as JSON result
      local output
      output=$(WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}" bash "$resolved" "${script_args[@]}" 2>&1 | head -c 2000) || {
        echo "{\"tool_error\":\"run_suite_script\",\"reason\":\"exit code $?\"}"
        return 0
      }
      printf '{"result":%s}' "$(printf '%s' "$output" | jq -Rs . 2>/dev/null || echo '"output captured"')"
      ;;
    *)
      agent_tool_reject "$name" "unknown tool"
      return 0
      ;;
  esac
}

agent_tool_reject() {
  local name="$1" reason="$2"
  printf '{"tool_error":"%s","reason":"%s"}' "$name" "$reason"
}
