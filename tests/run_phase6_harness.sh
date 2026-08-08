#!/bin/bash
# run_phase6_harness.sh — ROADMAP M3 spawn-provider abstraction regression.
# Covers:
#   * spawn-provider.sh dispatches to hermes (SPAWN_PROVIDER=hermes) — fake
#     hermes stub on PATH.
#   * spawn-provider.sh dispatches to the suite's own local llm-call.sh
#     endpoint (SPAWN_PROVIDER=local) — fake OpenAI-compatible HTTP server.
#   * Provider failure is honest: unknown provider and dead local server both
#     exit non-zero (so the daemon records a job failure, not a silent skip).
#   * Daemon integration: run_spawn executes the shim for both providers and
#     --status outcomes (DaemonState) + spawn audit record both providers.
#
# Uses an isolated temp WORKSPACE and temp PATH. Does not touch the real
# project tree and never calls real hermes or a real LLM server.
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
trap 'rm -rf "$WS"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT
mkdir -p "$WS/memory" "$WS/bin"

# ── Fixtures: fake hermes + fake local OpenAI server ───────────────────────
section "fixture"
cat > "$WS/bin/hermes" << 'EOF'
#!/bin/bash
echo "FAKE_HERMES_OK task=$3"
echo "FAKE_HERMES_ARGS=$*"
exit 0
EOF
chmod +x "$WS/bin/hermes"

cat > "$WS/fake_server.py" << 'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT_FILE = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            user = json.loads(body)["messages"][-1]["content"]
        except Exception:
            user = ""
        resp = json.dumps({"choices": [{"message": {"content": "FAKE_LOCAL_OK::" + user[-40:]}}]})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a):
        pass
srv = HTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$WS/fake_server.py" "$WS/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$WS/port" ] && break; sleep 0.1; done
PORT=$(cat "$WS/port")
LLM_BASE_URL="http://127.0.0.1:$PORT/v1"
pass "fixtures: fake hermes + fake local server on port $PORT"

SHIM="$ROOT/core/spawn/spawn-provider.sh"
export PATH="$WS/bin:$PATH"

# ── 1. Shim: hermes provider ────────────────────────────────────────────────
section "shim-hermes"
OUT=$(SPAWN_PROVIDER=hermes bash "$SHIM" --task "encode today" 2>&1)
if [ $? -eq 0 ] && echo "$OUT" | grep -q "FAKE_HERMES_OK task=encode today"; then
  pass "hermes provider dispatches to hermes chat with the task"
else
  fail "hermes provider ($OUT)"
fi
if echo "$OUT" | grep -q -- "--source daemon"; then
  pass "hermes provider passes --source daemon"
else
  fail "hermes provider --source daemon ($OUT)"
fi
if SPAWN_PROVIDER=hermes bash "$SHIM" --task "t" --yolo 2>&1 | grep -q -- "--accept-hooks"; then
  pass "hermes provider --yolo adds --accept-hooks/--yolo"
else
  fail "hermes provider --yolo"
fi

# ── 2. Shim: local provider against the fake server ─────────────────────────
section "shim-local"
OUT=$(SPAWN_PROVIDER=local LLM_BASE_URL="$LLM_BASE_URL" bash "$SHIM" --task "encode today" 2>&1)
if [ $? -eq 0 ] && echo "$OUT" | grep -q "FAKE_LOCAL_OK::encode today"; then
  pass "local provider runs via llm-call.sh against the local endpoint"
else
  fail "local provider ($OUT)"
fi

# ── 3. Shim: honest failure paths ───────────────────────────────────────────
section "shim-failures"
DEAD_PORT=$((PORT + 1))
SPAWN_PROVIDER=local LLM_BASE_URL="http://127.0.0.1:$DEAD_PORT/v1" bash "$SHIM" --task "t" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass "local provider with dead server exits non-zero (recorded failure)"
else
  fail "local provider dead server exited 0"
fi
SPAWN_PROVIDER=bogus bash "$SHIM" --task "t" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  pass "unknown provider exits non-zero"
else
  fail "unknown provider exited 0"
fi
bash "$SHIM" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  pass "missing --task exits 2"
else
  fail "missing --task exit code"
fi
# The whole point of the new guard: hermes absent + local provider still runs
# (no silent skip). Move the fake hermes aside for this one test.
mv "$WS/bin/hermes" "$WS/bin/hermes.hidden"
OUT=$(SPAWN_PROVIDER=local LLM_BASE_URL="$LLM_BASE_URL" bash "$SHIM" --task "still works" 2>&1)
RC=$?
mv "$WS/bin/hermes.hidden" "$WS/bin/hermes"
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "FAKE_LOCAL_OK::still works"; then
  pass "local provider runs with hermes absent from PATH (no silent skip)"
else
  fail "local provider with hermes absent ($OUT)"
fi

# ── 4. Daemon integration: run_spawn via both providers ─────────────────────
section "daemon-integration"
run_spawn_case() {
  # $1 = provider; $2 = LLM_BASE_URL (empty for hermes); $3 = label
  python3 - "$ROOT/deep-brain-kernel.py" "$1" "$2" "$3" "$WS" << 'PY'
import asyncio, importlib.util, json, logging, os, sys
logging.disable(logging.CRITICAL)  # keep daemon log lines out of the captured JSON
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
provider, base_url, label, ws = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
os.environ["WORKSPACE"] = ws
dbk.SPAWN_PROVIDER = provider
state = dbk.DaemonState(dbk.DAEMON_STATE_FILE)
job = dbk.Job(label, "spawn", "*", "0", "Run the integration task", days="*")
# vram_limit=101 (never blocks), psi_threshold=999 (never blocks)
asyncio.run(dbk.run_spawn(job, vram_limit=101.0, spawn_timeout=120,
                          psi_threshold=999.0, enable_yolo=False, daemon_state=state))
stats = state.job_stats.get(label, {})
result = {"success": stats.get("success", 0), "failure": stats.get("failure", 0),
          "last_error": stats.get("last_error")}
print(json.dumps(result))
PY
}

INJ=$(run_spawn_case hermes "" "p6_hermes" )
if echo "$INJ" | jq -e '.success==1 and .failure==0' >/dev/null; then
  pass "run_spawn (hermes) records success outcome"
else
  fail "run_spawn hermes outcome ($INJ)"
fi
if grep -q '"provider": "hermes"' "$WS/memory/aibrain-spawn-audit.jsonl"; then
  pass "spawn audit records provider=hermes"
else
  fail "spawn audit provider=hermes"
fi

INJ=$(SPAWN_PROVIDER=local LLM_BASE_URL="$LLM_BASE_URL" run_spawn_case local "$LLM_BASE_URL" "p6_local" )
if echo "$INJ" | jq -e '.success==1 and .failure==0' >/dev/null; then
  pass "run_spawn (local) records success outcome"
else
  fail "run_spawn local outcome ($INJ)"
fi
if grep -q '"provider": "local"' "$WS/memory/aibrain-spawn-audit.jsonl"; then
  pass "spawn audit records provider=local"
else
  fail "spawn audit provider=local"
fi

INJ=$(SPAWN_PROVIDER=local LLM_BASE_URL="http://127.0.0.1:$((PORT + 2))/v1" run_spawn_case local "http://127.0.0.1:$((PORT + 2))/v1" "p6_dead" )
if echo "$INJ" | jq -e '.failure>=1 and .success==0' >/dev/null; then
  pass "run_spawn (local, dead server) records failure outcome"
else
  fail "run_spawn local dead server outcome ($INJ)"
fi

# ── 5. Config surface ───────────────────────────────────────────────────────
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
if [ "$DEFAULT_PROVIDER" = "hermes" ]; then
  pass "SPAWN_PROVIDER defaults to hermes"
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
