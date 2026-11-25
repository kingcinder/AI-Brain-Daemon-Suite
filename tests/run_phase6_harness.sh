#!/bin/bash
# run_phase6_harness.sh — ROADMAP M3 spawn-provider regression, Juno-direct.
# Covers:
#   * spawn-provider.sh has exactly ONE provider: juno (the default). It
#     dispatches to Juno's internal agentic loop (core/agent-loop), which
#     asks Juno through the helm queue via juno-ask.sh. The fixture runs a
#     FAKE JUNO DRAINER against the temp workspace queue that answers juno
#     tasks with {"answer":"FAKE_JUNO_OK::..."} — Juno's seat, stubbed.
#   * --yolo is accepted and ignored (Juno's loop has no approval gate).
#   * The loop's AGENT_STUB_JUNO seam works through the provider.
#   * Provider failure is honest: no drainer answer within the wait, an
#     unknown provider, and a missing Juno loop all exit non-zero (so the
#     daemon records a job failure, not a silent skip).
#   * Daemon integration: run_spawn executes the shim for the juno provider
#     and records success/failure outcomes (DaemonState) + the spawn audit
#     records provider=juno; the job gets a stable Juno session file.
#
# Uses an isolated temp WORKSPACE and temp PATH. Does not touch the real
# project tree and never calls a real Juno turn (the drainer is the stub).
#
# Usage: bash tests/run_phase6_harness.sh

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
# Pin BRAIN_WORKSPACE to the fixture too (Gated-Ingress Refactor
# 2026-11-20): the agent-loop's juno-ask resolves BRAIN_WORKSPACE
# before WORKSPACE, so an ambient BRAIN_WORKSPACE (the daemon's env
# sets it to the real tree) leaked into the fixture, the ask landed
# in the real queue, the fake drainer never saw it, and the loop
# burned its full wait — the failure that made the self-mod evaluate
# reject prop_8b37ab72c3f0829b on a phantom regression.
export BRAIN_WORKSPACE="$WORKSPACE"
trap 'rm -f "$WS/drainer.on" 2>/dev/null; rm -rf "$WS"' EXIT
mkdir -p "$WS/memory" "$WS/bin"

SHIM="$ROOT/core/spawn/spawn-provider.sh"
export PATH="$HOME/.local/bin:$PATH"

# ── Fixture: fake Juno drainer (helm queue contract) ───────────────────────
# Stands in for Juno's drain: polls the temp workspace queue via the real
# openclaw shim and answers "juno" tasks with a loop-protocol answer JSON.
section "fixture"
cat > "$WS/bin/fake-drainer.sh" << 'EOF'
#!/bin/bash
WS="$1"
while [ -f "$WS/drainer.on" ]; do
  OC="$(command -v openclaw || echo "$HOME/.local/bin/openclaw")"
  BRAIN_WORKSPACE="$WS" WORKSPACE="$WS" "$OC" drain:next --limit 5 2>/dev/null | while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r 'select(.type=="juno") | .id // empty' 2>/dev/null)
    [ -z "$id" ] && continue
    printf '%s' '{"answer":"FAKE_JUNO_OK"}' | BRAIN_WORKSPACE="$WS" WORKSPACE="$WS" "$OC" drain:respond "$id" >/dev/null 2>&1
  done
  sleep 0.3
done
EOF
chmod +x "$WS/bin/fake-drainer.sh"
DRAINER_PID=""
start_drainer() {
  touch "$WS/drainer.on"
  bash "$WS/bin/fake-drainer.sh" "$WS" &
  DRAINER_PID=$!
}
stop_drainer() {
  rm -f "$WS/drainer.on"
  if [ -n "${DRAINER_PID:-}" ]; then
    wait "$DRAINER_PID" 2>/dev/null
    DRAINER_PID=""
  fi
}
pass "fixture: fake Juno drainer ready (answers juno queue tasks)"

# ── 1. Shim: juno provider through the loop ─────────────────────────────────
section "shim-juno"
start_drainer
OUT=$(bash "$SHIM" --task "encode today" 2>&1)
RC=$?
stop_drainer
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "FAKE_JUNO_OK"; then
  pass "default provider (juno) dispatches through Juno's loop and returns her answer"
else
  fail "default provider ($OUT)"
fi
if grep -q '"type": "juno"' "$WS/memory/spawn-queue.jsonl" 2>/dev/null; then
  pass "queue records carry type \"juno\""
else
  fail "queue record type"
fi

start_drainer
OUT=$(SPAWN_PROVIDER=juno bash "$SHIM" --task "yolo task" --yolo 2>&1)
RC=$?
stop_drainer
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "FAKE_JUNO_OK"; then
  pass "SPAWN_PROVIDER=juno works and --yolo is accepted (ignored — no gate to bypass)"
else
  fail "explicit juno provider / --yolo ($OUT)"
fi

# ── 2. Shim: AGENT_STUB_JUNO seam through the provider ──────────────────────
section "shim-stub"
cat > "$WS/bin/stub-juno.sh" << 'EOF'
#!/bin/bash
echo '{"answer":"STUB_JUNO_OK"}'
EOF
chmod +x "$WS/bin/stub-juno.sh"
OUT=$(AGENT_STUB_JUNO="$WS/bin/stub-juno.sh" bash "$SHIM" --task "stub task" 2>&1)
if [ $? -eq 0 ] && echo "$OUT" | grep -q "STUB_JUNO_OK"; then
  pass "AGENT_STUB_JUNO seam answers through the provider's loop"
else
  fail "AGENT_STUB_JUNO seam ($OUT)"
fi

# ── 3. Shim: honest failure paths ───────────────────────────────────────────
section "shim-failures"
JUNO_TIMEOUT=6 bash "$SHIM" --task "t" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass "juno provider with no drainer answer within the wait exits non-zero (recorded failure)"
else
  fail "juno provider with no answer exited 0"
fi
SPAWN_PROVIDER=bogus bash "$SHIM" --task "t" >/dev/null 2>&1
if [ $? -eq 5 ]; then
  pass "unknown provider exits 5 (juno is the only provider)"
else
  fail "unknown provider exit code"
fi
bash "$SHIM" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  pass "missing --task exits 2"
else
  fail "missing --task exit code"
fi
mkdir -p "$WS/fakeroot/core/spawn"
cp "$SHIM" "$WS/fakeroot/core/spawn/spawn-provider.sh"
bash "$WS/fakeroot/core/spawn/spawn-provider.sh" --task "t" >/dev/null 2>&1
if [ $? -eq 6 ]; then
  pass "juno loop missing exits 6"
else
  fail "loop-missing exit code"
fi

# ── 4. juno-ask.sh direct round-trip ────────────────────────────────────────
section "juno-ask"
start_drainer
OUT=$(WORKSPACE="$WS" BRAIN_WORKSPACE="$WS" bash "$ROOT/skills/prefrontal-cortex-memory/scripts/juno-ask.sh" --user "hello juno" --timeout 30 2>&1)
RC=$?
stop_drainer
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "FAKE_JUNO_OK"; then
  pass "juno-ask.sh round-trips through the shim's juno: verbs (drainer answers)"
else
  fail "juno-ask round-trip ($OUT)"
fi

# ── 5. Daemon integration: run_spawn with the juno provider ─────────────────
section "daemon-integration"
run_spawn_case() {
  # $1 = label; $2 = spawn_timeout
  python3 - "$ROOT/deep-brain-kernel.py" "$1" "$2" "$WS" << 'PY'
import asyncio, importlib.util, json, logging, os, sys
logging.disable(logging.CRITICAL)  # keep daemon log lines out of the captured JSON
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
label, spawn_timeout, ws = sys.argv[2], float(sys.argv[3]), sys.argv[4]
os.environ["WORKSPACE"] = ws
dbk.SPAWN_PROVIDER = "juno"
state = dbk.DaemonState(dbk.DAEMON_STATE_FILE)
job = dbk.Job(label, "spawn", "*", "0", "Run the integration task", days="*")
# vram_limit=101 (never blocks), psi_threshold=999 (never blocks)
asyncio.run(dbk.run_spawn(job, vram_limit=101.0, spawn_timeout=spawn_timeout,
                          psi_threshold=999.0, enable_yolo=False, daemon_state=state))
stats = state.job_stats.get(label, {})
result = {"success": stats.get("success", 0), "failure": stats.get("failure", 0),
          "last_error": stats.get("last_error")}
print(json.dumps(result))
PY
}

start_drainer
INJ=$(run_spawn_case "p6_juno" 120)
stop_drainer
if echo "$INJ" | jq -e '.success==1 and .failure==0' >/dev/null; then
  pass "run_spawn (juno) records success outcome"
else
  fail "run_spawn juno outcome ($INJ)"
fi
if grep -q '"provider": "juno"' "$WS/memory/aibrain-spawn-audit.jsonl"; then
  pass "spawn audit records provider=juno"
else
  fail "spawn audit provider=juno"
fi
if [ -f "$WS/memory/agent-sessions/p6_juno.jsonl" ]; then
  pass "run_spawn gives the job a stable Juno session file (AGENT_SESSION_ID=job name)"
else
  fail "stable session file missing"
fi

INJ=$(JUNO_TIMEOUT=6 run_spawn_case "p6_dead" 60)
if echo "$INJ" | jq -e '.failure>=1 and .success==0' >/dev/null; then
  pass "run_spawn (juno, no drainer answer) records failure outcome"
else
  fail "run_spawn juno dead outcome ($INJ)"
fi

# ── 6. Config surface ───────────────────────────────────────────────────────
section "config"
DEFAULT_PROVIDER=$(python3 - "$ROOT/deep-brain-kernel.py" << 'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
print(dbk.SPAWN_PROVIDER)
PY
)
if [ "$DEFAULT_PROVIDER" = "juno" ]; then
  pass "SPAWN_PROVIDER defaults to juno"
else
  fail "SPAWN_PROVIDER default (got $DEFAULT_PROVIDER)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Phase 6 harness: $PASSES passed, $FAILURES failed"
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
