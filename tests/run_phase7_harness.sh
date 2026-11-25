#!/bin/bash
# run_phase7_harness.sh — Open Item 5 transcript bridge regression, Juno-direct.
# Covers:
#   * export-transcripts.sh reads Juno's own session files (per-message
#     JSONL, the shape corpus-sync maintains) and rewrites them into the
#     normalized per-message shape the memory preprocess parsers expect.
#   * The JUNO_SESSION_EXPORT seam: a command that writes session-level
#     JSONL (one whole-session object per line) to a file arg is transformed
#     the same way (tests use a Juno stub for this seam).
#   * Transform correctness: only user/assistant messages with text content
#     and a parseable timestamp survive; system/tool/empty messages skipped.
#   * The bridge feeds the preprocess pipeline: preprocess.sh consumes the
#     transformed transcript and writes signals.jsonl.
#   * Honest failure paths: Juno session source unavailable (exit 3) and
#     export failure (exit 4) — so the daemon records a job failure, not a
#     silent skip.
#   * Daemon integration: run_direct executes the wrapper skill script for
#     the transcript_export job and records the success/failure outcome.
#
# Uses an isolated temp WORKSPACE. Does not touch the real project tree and
# never reads Juno's real session files.
#
# Usage: bash tests/run_phase7_harness.sh

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
mkdir -p "$WS/memory" "$WS/bin" "$WS/sessions" "$WS/juno-src" \
         "$WS/skills/hippocampus-memory/scripts" "$WS/core/transcripts" \
         "$WS/fakehome/.openclaw/agents/main/sessions"

# ── Fixtures: Juno session files + Juno export stubs ───────────────────────
section "fixture"
# Juno's real session shape: per-message lines, content as text blocks.
cat > "$WS/juno-src/juno-conversation.jsonl" << 'EOF'
{"type":"message","id":"m1","timestamp":"2026-11-20T00:00:01.000000+00:00","message":{"role":"system","content":"session boot"}}
{"type":"message","id":"m2","timestamp":"2026-11-20T00:00:02.000000+00:00","message":{"role":"user","content":[{"type":"text","text":"encode today's experience"}]}}
{"type":"message","id":"m3","timestamp":"2026-11-20T00:00:03.000000+00:00","message":{"role":"assistant","content":[{"type":"text","text":"Signals encoded."}]}}
{"type":"message","id":"m4","timestamp":"2026-11-20T00:00:04.000000+00:00","message":{"role":"user","content":""}}
{"type":"message","id":"m5","message":{"role":"user","content":"drop me (no timestamp)"}}
EOF

# Juno export stub: writes session-level JSONL (whole-session objects with
# epoch timestamps) to the file given as its last argument.
cat > "$WS/bin/juno-export" << 'EOF'
#!/bin/bash
STAGE="${!#}"
cat > "$STAGE" << 'JSONL'
{"id":"sess-1","title":"bridge test","created_at":1785700000,"messages":[{"role":"system","content":"boot","timestamp":1785700001},{"role":"user","content":"encode today's experience","timestamp":1785700002},{"role":"assistant","content":[{"type":"text","text":"Signals encoded."}],"timestamp":1785700003},{"role":"user","content":"","timestamp":1785700004},{"role":"user","content":"drop me (no timestamp)"}]}
JSONL
exit 0
EOF
chmod +x "$WS/bin/juno-export"

cat > "$WS/bin/juno-export-fail" << 'EOF'
#!/bin/bash
echo "juno session export: simulated failure" >&2
exit 4
EOF
chmod +x "$WS/bin/juno-export-fail"

BRIDGE="$ROOT/core/transcripts/export-transcripts.sh"
pass "fixtures: Juno session files (per-message) + Juno export stubs (session-level, failing)"

# ── 1. Bridge: default mode reads Juno session files ────────────────────────
section "bridge-transform"
OUT=$(JUNO_SESSION_DIR="$WS/juno-src" TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
RC=$?
if [ $RC -eq 0 ] && [ -s "$WS/sessions/juno-sessions.jsonl" ]; then
  pass "bridge reads Juno session files and writes juno-sessions.jsonl"
else
  fail "bridge transform (rc=$RC: $OUT)"
fi

TOTAL=$(wc -l < "$WS/sessions/juno-sessions.jsonl" | tr -d ' ')
if [ "$TOTAL" -eq 2 ]; then
  pass "transform keeps only the 2 user/assistant messages with text ($TOTAL lines)"
else
  fail "transform message count (expected 2, got $TOTAL)"
fi
if python3 - "$WS/sessions/juno-sessions.jsonl" << 'PY'
import json, sys
ok = True
for line in open(sys.argv[1]):
    d = json.loads(line)
    if d.get("type") != "message":
        ok = False
    if d["message"]["role"] not in ("user", "assistant"):
        ok = False
    if not d.get("timestamp", "").endswith("Z"):
        ok = False
    if not str(d["message"]["content"]).strip():
        ok = False
sys.exit(0 if ok else 1)
PY
then
  pass "every line is per-message shape {type,message{role,content},timestamp ISO-8601}"
else
  fail "per-message shape validation"
fi
if grep -q '"content": "Signals encoded."' "$WS/sessions/juno-sessions.jsonl"; then
  pass "assistant content rendered from text blocks"
else
  fail "assistant text-block content"
fi
if grep -q '"role": "user"' "$WS/sessions/juno-sessions.jsonl" \
   && ! grep -q '"role": "system"' "$WS/sessions/juno-sessions.jsonl"; then
  pass "system/empty/no-timestamp messages skipped"
else
  fail "role filtering"
fi

# ── 2. Bridge: JUNO_SESSION_EXPORT seam (session-level objects) ─────────────
section "bridge-export-seam"
mkdir -p "$WS/sessions2"
OUT=$(JUNO_SESSION_EXPORT="$WS/bin/juno-export" TRANSCRIPT_DIR="$WS/sessions2" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
RC=$?
TOTAL2=$(wc -l < "$WS/sessions2/juno-sessions.jsonl" 2>/dev/null | tr -d ' ')
if [ $RC -eq 0 ] && [ "$TOTAL2" -eq 2 ] && grep -q "encode today" "$WS/sessions2/juno-sessions.jsonl"; then
  pass "JUNO_SESSION_EXPORT seam: session-level export transformed to the same 2 messages"
else
  fail "export seam (rc=$RC total=$TOTAL2: $OUT)"
fi

# ── 3. Bridge feeds the preprocess pipeline ─────────────────────────────────
section "preprocess-feed"
# preprocess.sh reads $HOME/.openclaw/agents/main/sessions — feed it the
# bridge output through a fake HOME so the chain is proven in isolation.
cp "$WS/sessions/juno-sessions.jsonl" "$WS/fakehome/.openclaw/agents/main/sessions/"
PP="$ROOT/skills/hippocampus-memory/scripts/preprocess.sh"
OUT=$(HOME="$WS/fakehome" WORKSPACE="$WS" bash "$PP" --full 2>&1)
RC=$?
if [ $RC -eq 0 ] && [ -s "$WS/memory/signals.jsonl" ]; then
  pass "preprocess.sh consumes the transformed transcript and writes signals.jsonl"
else
  fail "preprocess feed (rc=$RC: $OUT)"
fi
if grep -q "encode today" "$WS/memory/signals.jsonl"; then
  pass "user message text appears in the preprocessed signals"
else
  fail "signal content ($OUT)"
fi

# ── 4. Bridge: honest failure paths ─────────────────────────────────────────
section "bridge-failures"
OUT=$(JUNO_SESSION_DIR="$WS/no-such-dir" TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
RC=$?
if [ $RC -eq 3 ]; then
  pass "Juno session source unavailable exits 3"
else
  fail "source-missing exit code (got $RC)"
fi

OUT=$(JUNO_SESSION_EXPORT="$WS/bin/juno-export-fail" TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
if [ $? -eq 4 ]; then
  pass "Juno session export failure exits 4 (recorded job failure)"
else
  fail "export-failure exit code ($OUT)"
fi

# ── 5. Daemon integration: run_direct executes the wrapper ──────────────────
section "daemon-integration"
# Deploy the wrapper + bridge into the temp workspace (installed layout).
cp "$ROOT/skills/hippocampus-memory/scripts/export-transcripts.sh" \
   "$WS/skills/hippocampus-memory/scripts/export-transcripts.sh"
cp "$ROOT/core/transcripts/export-transcripts.sh" "$WS/core/transcripts/export-transcripts.sh"
chmod +x "$WS/skills/hippocampus-memory/scripts/export-transcripts.sh" \
         "$WS/core/transcripts/export-transcripts.sh"

run_direct_case() {
  # $1 = mode: ok | fail ; $2 = label
  python3 - "$ROOT/deep-brain-kernel.py" "$1" "$2" "$WS" << 'PY'
import asyncio, importlib.util, json, logging, os, sys
logging.disable(logging.CRITICAL)  # keep daemon log lines out of the captured JSON
mode, label, ws = sys.argv[2], sys.argv[3], sys.argv[4]
# WORKSPACE must be set BEFORE exec_module: the daemon binds its paths at import.
os.environ["WORKSPACE"] = ws
os.environ["TRANSCRIPT_DIR"] = ws + "/sessions"
os.environ["JUNO_SESSION_DIR"] = ws + "/juno-src"
if mode == "fail":
    os.environ["JUNO_SESSION_EXPORT"] = ws + "/bin/juno-export-fail"
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
state = dbk.DaemonState(dbk.DAEMON_STATE_FILE)
job = dbk.Job(label, "direct", "5,11,17,23", "58",
              "hippocampus-memory/scripts/export-transcripts.sh")
asyncio.run(dbk.run_direct(job, direct_timeout=60, daemon_state=state))
stats = state.job_stats.get(label, {})
print(json.dumps({"success": stats.get("success", 0),
                  "failure": stats.get("failure", 0),
                  "last_error": stats.get("last_error")}))
PY
}

rm -f "$WS/sessions/juno-sessions.jsonl"
INJ=$(run_direct_case "ok" "p7_transcript")
if echo "$INJ" | jq -e '.success==1 and .failure==0' >/dev/null; then
  pass "run_direct (transcript_export) records success outcome"
else
  fail "run_direct success outcome ($INJ)"
fi
if [ -s "$WS/sessions/juno-sessions.jsonl" ]; then
  pass "daemon-driven run produced the transformed transcript"
else
  fail "daemon-driven transcript missing"
fi

INJ=$(run_direct_case "fail" "p7_transcript_fail")
if echo "$INJ" | jq -e '.failure>=1 and .success==0' >/dev/null; then
  pass "run_direct (export failure) records failure outcome — no silent skip"
else
  fail "run_direct failure outcome ($INJ)"
fi

# ── 6. Schedule surface: job is wired with a unique minute ──────────────────
section "schedule"
SCHED_OUT=$(python3 - "$ROOT/deep-brain-kernel.py" << 'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)
te = next((j for j in dbk.JOBS if j.name == "transcript_export"), None)
assert te is not None, "transcript_export job missing from JOBS"
assert te.kind == "direct", "transcript_export must be direct"
assert te.minutes == "58", "transcript_export minute must be unique (58)"
mins = set()
for j in dbk.JOBS:
    for m in str(j.minutes).split(","):
        assert m not in mins, f"minute collision on {m} ({j.name})"
        mins.add(m)
print("OK")
PY
)
if [ $? -eq 0 ]; then
  pass "transcript_export is a direct job on unique minute 58; no minute collisions"
else
  fail "schedule assertion failed ($SCHED_OUT)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Phase 7 harness: $PASSES passed, $FAILURES failed"
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
