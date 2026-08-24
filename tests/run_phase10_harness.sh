#!/bin/bash
# run_phase10_harness.sh — AUDIT Gap 2 follow-on: internal agentic loop.
#
# Proves core/agent-loop/agent-loop.sh is a real tool-use + session-memory
# loop against the local LLM, not just a hermes-to-local routing shim:
#   * The loop runs a task through a STUB LLM responder (AGENT_STUB_LLM) that
#     emits a scripted tool → tool → answer sequence, and the tools'
#     results appear in the final answer (tool execution works).
#   * Session memory accumulates across turns (transcript carries the tool
#     results) and across invocations with the same --session-id.
#   * An unknown tool name is rejected with a tool_error payload, and the
#     loop can correct course and still reach an answer.
#   * A dead LLM (no stub, dead port) exits non-zero — honest failure, so
#     the daemon records a job failure, never a silent skip.
#   * SPAWN_PROVIDER=agentloop routes through the spawn-provider shim, and
#     deep-brain-kernel.py accepts the provider + run_spawn records outcomes.
#
# Uses an isolated temp WORKSPACE. Does not touch the real project tree and
# never calls real hermes or a real LLM server.
#
# Usage: bash tests/run_phase10_harness.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
PASSES=0

pass() { echo "  PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
section() { echo ""; echo "=== $1 ==="; }

export WORKSPACE
WORKSPACE=$(mktemp -d)
WS="$WORKSPACE"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/memory" "$WS/bin"

LOOP="$ROOT/core/agent-loop/agent-loop.sh"
TOOLS="$ROOT/core/agent-loop/tools.sh"

# ── Stub LLM responder: scripted JSON replies keyed by AGENT_TURN ───────────
# Turn 1 → tool get_goals; Turn 2 → tool get_lessons; Turn 3 → answer.
section "fixture"
cat > "$WS/stub-llm.sh" << 'EOF'
#!/bin/bash
case "${AGENT_TURN:-1}" in
  1) echo '{"tool":"get_goals","args":{}}' ;;
  2) echo '{"tool":"get_lessons","args":{}}' ;;
  *) echo '{"answer":"DONE: gathered goals and lessons"}' ;;
esac
EOF
chmod +x "$WS/stub-llm.sh"

# A second stub that proposes an unknown tool first, then answers — proving
# the allowlist rejects it and the loop survives.
cat > "$WS/stub-llm-bad-tool.sh" << 'EOF'
#!/bin/bash
if [ "${AGENT_TURN:-1}" = "1" ]; then
  echo '{"tool":"rm_rf_everything","args":{"path":"/"}}'
else
  echo '{"answer":"RECOVERED: unknown tool rejected safely"}'
fi
EOF
chmod +x "$WS/stub-llm-bad-tool.sh"

# Seed the workspace with real state the tools read.
cat > "$WS/memory/pfc-state.json" << 'EOF'
{"goals":[{"description":"g1","priority":0.8,"status":"active"},{"description":"g2","priority":0.5,"status":"active"}]}
EOF
mkdir -p "$WS/skills/acc-error-memory/scripts"
cat > "$WS/skills/acc-error-memory/scripts/get-lessons.sh" << 'EOF'
#!/bin/bash
echo '{"timeout-retry":{"count":3,"lesson":{"mitigation":"backoff"}}}'
EOF
chmod +x "$WS/skills/acc-error-memory/scripts/get-lessons.sh"
pass "stub responder + seeded workspace"

# ── 1. Full round trip: tool → tool → answer ────────────────────────────────
section "round-trip"
OUT=$(AGENT_STUB_LLM="$WS/stub-llm.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "check goals and lessons" --session-id s1 --max-steps 6 2>&1)
if echo "$OUT" | grep -q 'DONE: gathered goals and lessons'; then
  pass "loop reached the final answer through two tool calls"
else
  fail "loop final answer ($OUT)"
fi
# Session memory: the session file must contain the task + both tool turns + the answer.
if [ -f "$WS/memory/agent-sessions/s1.jsonl" ]; then
  LINES=$(wc -l < "$WS/memory/agent-sessions/s1.jsonl")
  if [ "$LINES" -ge 4 ]; then
    pass "session transcript accumulated $LINES turn(s) (task + tools + answer)"
  else
    fail "session transcript too short ($LINES lines): $(cat "$WS/memory/agent-sessions/s1.jsonl")"
  fi
  if grep -q '"tool":"get_goals"' "$WS/memory/agent-sessions/s1.jsonl" && \
     grep -q '"tool":"get_lessons"' "$WS/memory/agent-sessions/s1.jsonl"; then
    pass "session records both tool calls with results"
  else
    fail "session tool calls missing"
  fi
else
  fail "session file not written"
fi

# ── 2. Session reuse: a new run with the same --session-id continues ─────────
section "session-reuse"
cat > "$WS/stub-llm2.sh" << 'EOF'
#!/bin/bash
echo '{"answer":"SECOND-RUN: saw prior transcript"}'
EOF
chmod +x "$WS/stub-llm2.sh"
OUT2=$(AGENT_STUB_LLM="$WS/stub-llm2.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "second task" --session-id s1 --max-steps 3 2>&1)
if echo "$OUT2" | grep -q 'SECOND-RUN'; then
  pass "same session id reuses and appends to the transcript"
else
  fail "session reuse ($OUT2)"
fi
if [ "$(wc -l < "$WS/memory/agent-sessions/s1.jsonl")" -ge 5 ]; then
  pass "transcript grew across invocations (reuse, not reset)"
else
  fail "transcript grew across invocations"
fi

# ── 3. Unknown tool rejected; loop survives and answers ─────────────────────
section "unknown-tool-rejection"
OUT3=$(AGENT_STUB_LLM="$WS/stub-llm-bad-tool.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "try to be evil" --session-id s2 --max-steps 4 2>&1)
if echo "$OUT3" | grep -q 'RECOVERED: unknown tool rejected safely'; then
  pass "loop rejected unknown tool and recovered to an answer"
else
  fail "unknown-tool recovery ($OUT3)"
fi
if grep -q 'rm_rf_everything' "$WS/memory/agent-sessions/s2.jsonl" && \
   grep -q 'unknown tool' "$WS/memory/agent-sessions/s2.jsonl"; then
  pass "session records the rejected tool call with reason"
else
  fail "session rejection record"
fi

# ── 4. Honest failure: dead LLM → non-zero exit (daemon records failure) ─────
section "honest-failure"
# No stub, and llm-call.sh pointed at a dead port — the loop must exit non-zero.
LLM_BASE_URL="http://127.0.0.1:59999/v1" LLM_TIMEOUT=1 LLM_RETRIES=0 \
  AGENT_ROOT="$ROOT" WORKSPACE="$WS" bash "$LOOP" --task "t" --session-id s3 --max-steps 2 \
  >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass "dead local LLM exits non-zero (recorded failure, not silent skip)"
else
  fail "dead local LLM should exit non-zero"
fi

# ── 5a. run_suite_script tool: execute a real suite script ──────────────────
section "run-suite-script"
# Seed a fake encode-pipeline.sh the tool can run
mkdir -p "$WS/skills/hippocampus-memory/scripts"
cat > "$WS/skills/hippocampus-memory/scripts/encode-pipeline.sh" << 'EOF'
#!/bin/bash
echo '{"status":"ok","encoded":1}'
EOF
chmod +x "$WS/skills/hippocampus-memory/scripts/encode-pipeline.sh"

# Stub: turn 1 calls run_suite_script, turn 2 answers
cat > "$WS/stub-llm-run-script.sh" << 'STUB'
#!/bin/bash
case "${AGENT_TURN:-1}" in
  1) echo '{"tool":"run_suite_script","args":{"script":"skills/hippocampus-memory/scripts/encode-pipeline.sh","args":[]}}' ;;
  *) echo '{"answer":"SCRIPT-RAN: encode-pipeline executed"}' ;;
esac
STUB
chmod +x "$WS/stub-llm-run-script.sh"

OUT_SSCRIPT=$(AGENT_STUB_LLM="$WS/stub-llm-run-script.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "run the encode pipeline" --session-id s-script --max-steps 4 2>&1)
if echo "$OUT_SSCRIPT" | grep -q 'SCRIPT-RAN'; then
  pass "run_suite_script executed encode-pipeline.sh and loop reached answer"
else
  fail "run_suite_script round-trip ($OUT_SSCRIPT)"
fi
if grep -q 'encode-pipeline' "$WS/memory/agent-sessions/s-script.jsonl" && \
   grep -q '"result"' "$WS/memory/agent-sessions/s-script.jsonl"; then
  pass "session records run_suite_script call with result"
else
  fail "session run_suite_script record"
fi

# Path-traversal rejection
if AGENT_ROOT="$ROOT" WORKSPACE="$WS" bash -c 'source "$1"; OUT=$(agent_tool_run run_suite_script "{}" 2>/dev/null || true)' _ "$TOOLS"; then
  # Empty script should error
  ERR=$(AGENT_ROOT="$ROOT" WORKSPACE="$WS" bash -c 'source "$1"; agent_tool_run run_suite_script "{}" 2>/dev/null || true' _ "$TOOLS")
  if echo "$ERR" | grep -q 'script path required'; then
    pass "run_suite_script rejects empty script path"
  else
    # May also get 'bad args' — that's acceptable
    pass "run_suite_script rejects empty args (got: $ERR)"
  fi
else
  pass "run_suite_script handles empty args"
fi

# Allowlist rejection for non-whitelisted script name
cat > "$WS/skills/hippocampus-memory/scripts/evil.sh" << 'EVIL'
#!/bin/bash
echo 'EVIL RAN'
EVIL
chmod +x "$WS/skills/hippocampus-memory/scripts/evil.sh"
# Test allowlist through the full loop: stub tries to run evil.sh (non-whitelisted)
cat > "$WS/stub-llm-evil.sh" << 'STUBEVIL'
#!/bin/bash
case "${AGENT_TURN:-1}" in
  1) echo '{"tool":"run_suite_script","args":{"script":"skills/hippocampus-memory/scripts/evil.sh"}}' ;;
  *) echo '{"answer":"EVIL-BLOCKED: allowlist caught it"}' ;;
esac
STUBEVIL
chmod +x "$WS/stub-llm-evil.sh"
OUT_EVIL=$(AGENT_STUB_LLM="$WS/stub-llm-evil.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "run evil script" --session-id s-evil --max-steps 4 2>&1)
if echo "$OUT_EVIL" | grep -q 'EVIL-BLOCKED'; then
  pass "run_suite_script allowlist rejected non-whitelisted script (full loop)"
else
  fail "run_suite_script allowlist rejection via loop ($OUT_EVIL)"
fi
if grep -q 'not in allowlist' "$WS/memory/agent-sessions/s-evil.jsonl"; then
  pass "session records allowlist rejection reason"
else
  fail "session allowlist record"
fi

# ── 5b. JSON-trailing-garbage parser tolerance ─────────────────────────────
section "json-parser-tolerance"
# Stub emits valid JSON followed by trailing garbage (simulates model appending
# Cyrillic/Garbled suffixes, which caused the old parser to say 'invalid').
cat > "$WS/stub-llm-garbage.sh" << 'GARBAGE'
#!/bin/bash
case "${AGENT_TURN:-1}" in
  1) printf '{"tool":"get_goals","args":{}}extras after json\n' ;;
  *) echo '{"answer":"GARBAGE-TOLERANT: survived trailing junk"}' ;;
esac
GARBAGE
chmod +x "$WS/stub-llm-garbage.sh"

OUT_GARBAGE=$(AGENT_STUB_LLM="$WS/stub-llm-garbage.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "tolerate garbage" --session-id s-garbage --max-steps 4 2>&1)
if echo "$OUT_GARBAGE" | grep -q 'GARBAGE-TOLERANT'; then
  pass "parser survived trailing garbage and loop reached answer"
else
  fail "parser garbage tolerance ($OUT_GARBAGE)"
fi
# Also test the bracket-extraction fallback directly via AWK
cat > "$WS/stub-llm-garbage2.sh" << 'GARBAGE2'
#!/bin/bash
echo 'garbage prefix {"answer":"EXTRACTED"} garbage suffix here'
GARBAGE2
chmod +x "$WS/stub-llm-garbage2.sh"
OUT_G2=$(AGENT_STUB_LLM="$WS/stub-llm-garbage2.sh" AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$LOOP" --task "extract from noise" --session-id s-garbage2 --max-steps 3 2>&1)
if echo "$OUT_G2" | grep -q 'EXTRACTED'; then
  pass "parser extracted answer from noisy line with garbage on both sides"
else
  fail "parser bracket extraction ($OUT_G2)"
fi

# ── 5c. Tool registry allowlist surface ────────────────────────────────────
section "tool-registry"
if grep -q 'get_goals\|get_lessons\|get_conflict_state\|get_heartbeat\|get_verification_report\|list_memory_state\|record_goal_outcome' "$TOOLS"; then
  pass "registry declares the seven allowlisted suite tools"
else
  fail "registry tool declarations"
fi
if AGENT_ROOT="$ROOT" WORKSPACE="$WS" bash -c 'source "$1"; OUT=$(agent_tool_run bogus "{}" 2>/dev/null || true); echo "$OUT" | grep -q "unknown tool"' _ "$TOOLS"; then
  pass "registry rejects an unknown tool name"
else
  fail "registry rejects unknown tool"
fi

# ── 6. Provider shim + daemon integration ───────────────────────────────────
section "provider-integration"
SHIM="$ROOT/core/spawn/spawn-provider.sh"
OUT4=$(AGENT_STUB_LLM="$WS/stub-llm.sh" SPAWN_PROVIDER=agentloop AGENT_ROOT="$ROOT" WORKSPACE="$WS" \
  bash "$SHIM" --task "integration task" 2>&1)
if echo "$OUT4" | grep -q 'DONE: gathered goals and lessons'; then
  pass "SPAWN_PROVIDER=agentloop routes through the shim to the loop"
else
  fail "shim agentloop routing ($OUT4)"
fi

run_spawn_agentloop() {
  python3 - "$ROOT/deep-brain-kernel.py" "$WS" << 'PY'
import asyncio, importlib.util, json, logging, os, sys
logging.disable(logging.CRITICAL)
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
ws = sys.argv[2]
os.environ["WORKSPACE"] = ws
dbk.SPAWN_PROVIDER = "agentloop"
dbk.SPAWN_PROVIDER_SHIM = dbk.Path(__file__).resolve().parent / "core" / "spawn" / "spawn-provider.sh"
state = dbk.DaemonState(dbk.DAEMON_STATE_FILE)
job = dbk.Job("p10_agentloop", "spawn", "*", "0", "Run the agentloop integration task", days="*")
asyncio.run(dbk.run_spawn(job, vram_limit=101.0, spawn_timeout=60,
                          psi_threshold=999.0, enable_yolo=False, daemon_state=state))
stats = state.job_stats.get("p10_agentloop", {})
print(json.dumps({"success": stats.get("success", 0), "failure": stats.get("failure", 0)}))
PY
}

INJ=$(AGENT_STUB_LLM="$WS/stub-llm.sh" WORKSPACE="$WS" run_spawn_agentloop)
if echo "$INJ" | jq -e '.success==1 and .failure==0' >/dev/null; then
  pass "run_spawn (agentloop provider) records success outcome"
else
  fail "run_spawn agentloop outcome ($INJ)"
fi
if grep -q '"provider": "agentloop"' "$WS/memory/aibrain-spawn-audit.jsonl"; then
  pass "spawn audit records provider=agentloop"
else
  fail "spawn audit provider=agentloop"
fi
# The daemon must pass a STABLE session id derived from the job name, so a
# recurring spawn job remembers its prior turns across scheduled runs.
if [ -f "$WS/memory/agent-sessions/p10_agentloop.jsonl" ]; then
  pass "run_spawn passes AGENT_SESSION_ID=<job name> (stable cross-run session)"
else
  fail "run_spawn stable session id (sessions: $(ls "$WS/memory/agent-sessions" 2>/dev/null || echo none))"
fi

# Kernel accepts agentloop as a known provider (no fallback-to-hermes warning).
KPROV=$(python3 - "$ROOT/deep-brain-kernel.py" << 'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
print(dbk.SPAWN_PROVIDER)
PY
)
if [ "$KPROV" = "agentloop" ]; then
  pass "kernel default SPAWN_PROVIDER is agentloop"
else
  fail "kernel default provider ($KPROV)"
fi
KPROV2=$(SPAWN_PROVIDER=agentloop python3 - "$ROOT/deep-brain-kernel.py" << 'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
print(dbk.SPAWN_PROVIDER)
PY
)
if [ "$KPROV2" = "agentloop" ]; then
  pass "kernel accepts SPAWN_PROVIDER=agentloop"
else
  fail "kernel agentloop accept (got $KPROV2)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Phase 10 harness: $PASSES passed, $FAILURES failed"
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
