#!/bin/bash
# run_phase7_harness.sh — Open Item 5 transcript bridge regression.
# Covers:
#   * export-transcripts.sh runs `hermes sessions export --format jsonl`
#     (fake hermes stub on PATH) and rewrites the session-level export into
#     the per-message shape the memory preprocess parsers expect.
#   * Transform correctness: only user/assistant messages with text content
#     and a parseable timestamp survive; system/tool/empty messages skipped.
#   * The bridge feeds the preprocess pipeline: preprocess.sh consumes the
#     transformed transcript and writes signals.jsonl.
#   * Honest failure paths: hermes missing (exit 3) and export failure
#     (exit 4) — so the daemon records a job failure, not a silent skip.
#   * Daemon integration: run_direct executes the wrapper skill script for
#     the transcript_export job and records the success/failure outcome.
#
# Uses an isolated temp WORKSPACE and temp PATH. Does not touch the real
# project tree and never calls real hermes.
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
mkdir -p "$WS/memory" "$WS/bin" "$WS/sessions" "$WS/skills/hippocampus-memory/scripts" "$WS/core/transcripts"

# ── Fixtures: fake hermes (success + failing variants) ─────────────────────
section "fixture"
cat > "$WS/bin/hermes" << 'EOF'
#!/bin/bash
# Fake `hermes sessions export --format jsonl [--newer-than AGE] --yes <file>`
# Writes a session-level export (one whole-session JSON object per LINE) to
# the LAST argument, mirroring the real hermes schema observed in the field.
STAGE="${!#}"
cat > "$STAGE" << 'JSONL'
{"id":"sess-1","title":"bridge test","created_at":1785700000,"messages":[{"role":"system","content":"You are Hermes.","timestamp":1785700001},{"role":"user","content":"encode today's experience","timestamp":1785700002},{"role":"assistant","content":[{"type":"text","text":"Signals encoded."}],"timestamp":1785700003},{"role":"user","content":"","timestamp":1785700004},{"role":"user","content":"drop me (no timestamp)"}]}
JSONL
exit 0
EOF
chmod +x "$WS/bin/hermes"

cat > "$WS/bin/hermes-fail" << 'EOF'
#!/bin/bash
echo "hermes sessions export: simulated failure" >&2
exit 4
EOF
chmod +x "$WS/bin/hermes-fail"

cat > "$WS/bin/hermes-no-export" << 'EOF'
#!/bin/bash
# hermes exists but does not support sessions export (missing subcommand)
exit 1
EOF
chmod +x "$WS/bin/hermes-no-export"

BRIDGE="$ROOT/core/transcripts/export-transcripts.sh"
export PATH="$WS/bin:$PATH"
pass "fixtures: fake hermes (success/fail/no-export) on temp PATH"

# ── 1. Bridge: export + transform to per-message shape ──────────────────────
section "bridge-transform"
OUT=$(TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
RC=$?
if [ $RC -eq 0 ] && [ -s "$WS/sessions/hermes-sessions.jsonl" ]; then
  pass "bridge runs hermes sessions export and writes hermes-sessions.jsonl"
else
  fail "bridge export+transform (rc=$RC: $OUT)"
fi

TOTAL=$(wc -l < "$WS/sessions/hermes-sessions.jsonl" | tr -d ' ')
if [ "$TOTAL" -eq 2 ]; then
  pass "transform keeps only the 2 user/assistant messages with text ($TOTAL lines)"
else
  fail "transform message count (expected 2, got $TOTAL)"
fi
if python3 - "$WS/sessions/hermes-sessions.jsonl" << 'PY'
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
if grep -q '"content": "Signals encoded."' "$WS/sessions/hermes-sessions.jsonl"; then
  pass "assistant content rendered from text blocks"
else
  fail "assistant text-block content"
fi
if grep -q '"role": "user"' "$WS/sessions/hermes-sessions.jsonl" \
   && ! grep -q '"role": "system"' "$WS/sessions/hermes-sessions.jsonl"; then
  pass "system/empty/no-timestamp messages skipped"
else
  fail "role filtering"
fi

# ── 2. Bridge feeds the preprocess pipeline ─────────────────────────────────
section "preprocess-feed"
PP="$ROOT/skills/hippocampus-memory/scripts/preprocess.sh"
OUT=$(TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$PP" --full 2>&1)
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

# ── 3. Bridge: honest failure paths ─────────────────────────────────────────
section "bridge-failures"
# The real hermes binary exists on this host, so 'missing from PATH' is tested
# via an explicit HERMES_BIN that resolves to nothing — the same exit-3 guard.
OUT=$(HERMES_BIN=hermes-nonexistent-xyz TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
RC=$?
if [ $RC -eq 3 ]; then
  pass "hermes binary missing exits 3"
else
  fail "hermes-missing exit code (got $RC)"
fi

OUT=$(HERMES_BIN=hermes-fail TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
if [ $? -eq 4 ]; then
  pass "hermes sessions export failure exits 4 (recorded job failure)"
else
  fail "export-failure exit code ($OUT)"
fi

OUT=$(HERMES_BIN=hermes-no-export TRANSCRIPT_DIR="$WS/sessions" WORKSPACE="$WS" bash "$BRIDGE" 2>&1)
if [ $? -eq 4 ]; then
  pass "hermes without sessions export support exits 4"
else
  fail "no-export exit code ($OUT)"
fi

# ── 4. Daemon integration: run_direct executes the wrapper ──────────────────
section "daemon-integration"
# Deploy the wrapper + bridge into the temp workspace (installed layout).
cp "$ROOT/skills/hippocampus-memory/scripts/export-transcripts.sh" \
   "$WS/skills/hippocampus-memory/scripts/export-transcripts.sh"
cp "$ROOT/core/transcripts/export-transcripts.sh" "$WS/core/transcripts/export-transcripts.sh"
chmod +x "$WS/skills/hippocampus-memory/scripts/export-transcripts.sh" \
         "$WS/core/transcripts/export-transcripts.sh"

run_direct_case() {
  # $1 = HERMES_BIN ('' for default); $2 = label
  python3 - "$ROOT/deep-brain-kernel.py" "$1" "$2" "$WS" << 'PY'
import asyncio, importlib.util, json, logging, os, sys
logging.disable(logging.CRITICAL)  # keep daemon log lines out of the captured JSON
hermes_bin, label, ws = sys.argv[2], sys.argv[3], sys.argv[4]
# WORKSPACE must be set BEFORE exec_module: the daemon binds its paths at import.
os.environ["WORKSPACE"] = ws
os.environ["TRANSCRIPT_DIR"] = ws + "/sessions"
os.environ["PATH"] = ws + "/bin:" + os.environ.get("PATH", "")
if hermes_bin:
    os.environ["HERMES_BIN"] = hermes_bin
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

INJ=$(run_direct_case "" "p7_transcript")
if echo "$INJ" | jq -e '.success==1 and .failure==0' >/dev/null; then
  pass "run_direct (transcript_export) records success outcome"
else
  fail "run_direct success outcome ($INJ)"
fi
if [ -s "$WS/sessions/hermes-sessions.jsonl" ]; then
  pass "daemon-driven run produced the transformed transcript"
else
  fail "daemon-driven transcript missing"
fi

rm -f "$WS/sessions/hermes-sessions.jsonl"
INJ=$(run_direct_case "hermes-fail" "p7_transcript_fail")
if echo "$INJ" | jq -e '.failure>=1 and .success==0' >/dev/null; then
  pass "run_direct (export failure) records failure outcome — no silent skip"
else
  fail "run_direct failure outcome ($INJ)"
fi

# ── 5. Schedule surface: job is wired with a unique minute ──────────────────
section "schedule"
python3 - "$ROOT/deep-brain-kernel.py" << 'PY' > /dev/null 2>&1 || true
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
RC=$?
if [ $RC -eq 0 ]; then
  pass "transcript_export is a direct job on unique minute 58; no minute collisions"
else
  fail "schedule assertion failed (rc=$RC)"
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
