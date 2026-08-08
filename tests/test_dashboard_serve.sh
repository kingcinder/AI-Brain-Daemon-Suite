#!/bin/bash
# test_dashboard_serve.sh — Unit tests for the Brain Dashboard serve mode.
#
# Tests:
#  1. serve-dashboard.sh start launches the server and serves HTTP 200
#  2. The served page injects the auto-refresh script (polls /__dashboard_mtime)
#  3. /__dashboard_mtime returns the dashboard file's mtime as JSON
#  4. Regenerating the dashboard changes the mtime (the auto-refresh trigger)
#  5. Static-file serving works and `..` traversal is blocked
#  6. serve-dashboard.sh status/stop lifecycle works (status 0 → stop → status 1)
#
# Run: bash tests/test_dashboard_serve.sh
# Requires: python3, curl (both already in the Suite's dependency set)

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
SERVER_PID=""

# Pick a free port dynamically so parallel/local runs never collide.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE="$TEST_WORKSPACE"
export DASHBOARD_HOST="127.0.0.1"
export DASHBOARD_PORT="$PORT"
export DASHBOARD_PID_FILE="$TEST_WORKSPACE/.dashboard-server.pid"
export DASHBOARD_LOG="$TEST_WORKSPACE/.dashboard-server.log"
export DASHBOARD_REFRESH_SECONDS="1"  # fast poll so tests don't wait

# A minimal dashboard fixture with a </body> so the injection has a target.
cat > "$TEST_WORKSPACE/brain-dashboard.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Brain Dashboard</title></head>
<body>
<div class="card"><div class="stat-val">fixture</div></div>
</body>
</html>
EOF

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # Belt-and-braces: launcher stop also cleans its own PID file.
    "$ROOT/scripts/serve-dashboard.sh" stop >/dev/null 2>&1 || true
    rm -rf "$TEST_WORKSPACE"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── Test 1: start launches the server, serves HTTP 200 ──────────────────
echo "Test 1: serve-dashboard.sh start serves the dashboard"

START_OUT=$("$ROOT/scripts/serve-dashboard.sh" start 2>&1) || {
    fail "serve-dashboard.sh start failed: $START_OUT"
}
if [ -f "$DASHBOARD_PID_FILE" ]; then
    SERVER_PID=$(cat "$DASHBOARD_PID_FILE")
fi
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/brain-dashboard.html")
if [ "$HTTP_CODE" = "200" ]; then
    pass "server serves brain-dashboard.html (HTTP $HTTP_CODE, pid ${SERVER_PID:-unknown})"
else
    fail "expected HTTP 200, got $HTTP_CODE"
fi

# ── Test 2: auto-refresh script injected into served HTML ───────────────
echo "Test 2: auto-refresh script is injected"

BODY=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/brain-dashboard.html")
# Bash-native substring match (NOT `echo "$BODY" | grep -q`): under
# `set -o pipefail`, grep -q exits on first match and echo dies with SIGPIPE
# mid-write of the full body, flipping the pipeline to a false failure.
if [[ "$BODY" == *__dashboard_mtime* ]] && [[ "$BODY" == *'location.reload'* ]]; then
    pass "served HTML contains the auto-refresh poller"
else
    fail "served HTML missing the auto-refresh script"
fi
# The on-disk file must be untouched — injection is serve-time only.
if grep -q "__dashboard_mtime" "$TEST_WORKSPACE/brain-dashboard.html"; then
    fail "on-disk dashboard was modified by the server"
else
    pass "on-disk dashboard file is pristine (injection is serve-time only)"
fi

# ── Test 3: /__dashboard_mtime returns JSON mtime ───────────────────────
echo "Test 3: /__dashboard_mtime returns the file's mtime"

MTIME1=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__dashboard_mtime")
if echo "$MTIME1" | jq -e '.mtime > 0' >/dev/null 2>&1; then
    pass "mtime endpoint returns positive mtime ($(echo "$MTIME1" | jq -c .))"
else
    fail "mtime endpoint malformed: $MTIME1"
fi

# ── Test 4: regenerating the dashboard changes the mtime ────────────────
echo "Test 4: regeneration bumps mtime (the auto-refresh trigger)"

sleep 1.1  # ensure a distinct mtime
printf '\n<!-- regenerated -->\n' >> "$TEST_WORKSPACE/brain-dashboard.html"
MTIME2=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__dashboard_mtime")
if [ -n "$MTIME2" ] && [ "$(echo "$MTIME1" | jq -r '.mtime')" != "$(echo "$MTIME2" | jq -r '.mtime')" ]; then
    pass "mtime changed after regeneration ($(echo "$MTIME1" | jq -r '.mtime') → $(echo "$MTIME2" | jq -r '.mtime'))"
else
    fail "mtime did not change after regeneration"
fi

# ── Test 5: static serving + traversal + asset whitelist ────────────────
echo "Test 5: static serving, traversal guard, and asset whitelist"

echo 'body { color: black; }' > "$TEST_WORKSPACE/probe.css"
STATIC_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/probe.css")
TRAV_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/../../../../etc/passwd")
if [ "$STATIC_CODE" = "200" ]; then
    pass "browser asset served (probe.css HTTP $STATIC_CODE)"
else
    fail "browser asset should be 200, got $STATIC_CODE"
fi
if [ "$TRAV_CODE" = "404" ] || [ "$TRAV_CODE" = "403" ]; then
    pass "path traversal blocked (HTTP $TRAV_CODE)"
else
    fail "path traversal should be blocked, got $TRAV_CODE"
fi
# Non-GUI workspace internals (brain state, scripts, keys-adjacent) must 404.
echo '{"probe": true}' > "$TEST_WORKSPACE/memory-probe.json"
JSON_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/memory-probe.json")
PY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/probe.py")
if [ "$JSON_CODE" = "404" ] && [ "$PY_CODE" = "404" ]; then
    pass "non-GUI workspace files blocked (.json HTTP $JSON_CODE, .py HTTP $PY_CODE)"
else
    fail "workspace internals must 404 — .json=$JSON_CODE .py=$PY_CODE"
fi

# ── Test 6: live-status endpoints ───────────────────────────────────────
echo "Test 6: /__fragments, /__daemon, and /__regenerate endpoints"

FRAGS=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__fragments")
if echo "$FRAGS" | jq -e '(.count | type) == "number" and (.fragments | type) == "array"' >/dev/null 2>&1; then
    pass "/__fragments returns fragment inventory (count=$(echo "$FRAGS" | jq -r '.count'))"
else
    fail "/__fragments malformed: $FRAGS"
fi

DAEMON=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__daemon")
if echo "$DAEMON" | jq -e '(.heartbeat == null or (.heartbeat | type) == "object") and (.jobs | type) == "object" and (.summary | type) == "object"' >/dev/null 2>&1; then
    pass "/__daemon returns heartbeat + jobs + summary"
else
    fail "/__daemon malformed: $DAEMON"
fi

# M5: seed a per-run outcome ledger, then /__daemon must surface a per-job
# success-rate trend (the daemon-health sparkline source).
mkdir -p "$TEST_WORKSPACE/memory"
cat > "$TEST_WORKSPACE/memory/daemon-job-history.jsonl" << 'EOF'
{"ts":"2026-08-08T07:00:00Z","job":"heartbeat_beat","success":true}
{"ts":"2026-08-08T08:00:00Z","job":"verification_pass","success":true}
{"ts":"2026-08-08T09:00:00Z","job":"verification_pass","success":false}
{"ts":"2026-08-08T10:00:00Z","job":"verification_pass","success":true}
EOF
DAEMON2=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__daemon")
if echo "$DAEMON2" | jq -e '(.jobs.history.verification_pass.runs == 3) and (.jobs.history.verification_pass.success_rate | type) == "number" and (.jobs.history.heartbeat_beat.recent | type) == "array"' >/dev/null 2>&1; then
    pass "/__daemon computes per-job success-rate history from the ledger"
else
    fail "/__daemon history malformed: $DAEMON2"
fi
rm -f "$TEST_WORKSPACE/memory/daemon-job-history.jsonl"

# The regenerate endpoint must reject anonymous POSTs (token-gated mutation).
REGEN_NO_TOKEN=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST "http://127.0.0.1:$PORT/__regenerate")
if [ "$REGEN_NO_TOKEN" = "403" ]; then
    pass "POST /__regenerate without token is rejected (HTTP $REGEN_NO_TOKEN)"
else
    fail "expected 403 for tokenless regenerate, got $REGEN_NO_TOKEN"
fi

# The regenerate endpoint rebuilds the dashboard from each skill's
# sync-state.sh / generate-dashboard.sh. verification-memory's fragment (the
# 🩺 tab, incl. the autonomy contract history card) is only written when
# verification-state.json exists — seed it so the rebuilt page genuinely
# carries the card and every skill is exercised by the rebuild.
mkdir -p "$TEST_WORKSPACE/memory"
cat > "$TEST_WORKSPACE/memory/verification-state.json" << 'EOF'
{"lastRun": "2026-08-08T07:00:00Z", "totals": {"tests": 21, "passed": 21, "failed": 0}, "lastFailure": []}
EOF

# With the token injected into the served page, regenerate must succeed and
# report which skills ran.
BODY=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/brain-dashboard.html")
TOKEN=$(echo "$BODY" | sed -n 's/.*window.__DASH_TOKEN = "\([a-f0-9]*\)".*/\1/p' | head -1)
if [ -n "$TOKEN" ]; then
    REGEN_OK=$(curl -s --max-time 60 -X POST "http://127.0.0.1:$PORT/__regenerate" -H "X-Dashboard-Token: $TOKEN")
    if echo "$REGEN_OK" | jq -e '(.ran | type) == "array"' >/dev/null 2>&1; then
        pass "POST /__regenerate with token succeeds ($(echo "$REGEN_OK" | jq -c '.ran') ran)"
    else
        fail "regenerate with token failed: $REGEN_OK"
    fi
else
    fail "token not injected into served page"
fi

# M7/M8: seed an autonomy contract, then /__daemon must surface mode + evidence
# (the status-bar autonomy pill source).
mkdir -p "$TEST_WORKSPACE/memory/self-mod"
cat > "$TEST_WORKSPACE/memory/self-mod/autonomy-state.json" << 'EOF'
{
  "mode": "auto_mode",
  "auto": true,
  "computed_at": "2026-08-08T10:00:00Z",
  "evidence": {"graduated": true, "clean_streak": 22, "clean_streak_target": 20, "unhealthy_jobs": 0, "auto_rollbacks_in_window": 1, "max_auto_rollbacks": 3, "window_days": 30}
}
EOF
# Autonomy contract history: seed the append-only ledger (what --autonomy
# writes each run) and assert /__daemon surfaces it for the 🩺 tab timeline.
cat > "$TEST_WORKSPACE/memory/self-mod/autonomy-history.jsonl" << 'EOF'
{"ts":"2026-08-01T09:00:00Z","mode":"steward_mode","auto":false,"transition":"initial","evidence":{"graduated":false,"clean_streak":5,"clean_streak_target":20,"unhealthy_jobs":0,"auto_rollbacks_in_window":0,"max_auto_rollbacks":3}}
{"ts":"2026-08-08T09:00:00Z","mode":"auto_mode","auto":true,"transition":"granted","evidence":{"graduated":true,"clean_streak":25,"clean_streak_target":20,"unhealthy_jobs":0,"auto_rollbacks_in_window":0,"max_auto_rollbacks":3}}
EOF
# Autonomy gate provenance: seed the audit ledger (what log-provenance.sh
# event writes) and assert /__daemon surfaces it for the 🛠 Self-Mod tab's
# gate timeline.
mkdir -p "$TEST_WORKSPACE/memory/provenance"
cat > "$TEST_WORKSPACE/memory/provenance/events.jsonl" << 'EOF'
{"ts":"2026-08-06T09:00:00Z","event":"autonomy.mode.decided","actor":"deep-brain-kernel","detail":{"mode":"steward_mode","auto":false,"transition":"initial"}}
{"ts":"2026-08-07T09:00:00Z","event":"autonomy.gate.deferred","actor":"run-pipeline","detail":{"autonomy_mode":"steward_mode","review_mode":"full_review","reason":"steward_full_review_deferred"}}
{"ts":"2026-08-08T09:00:00Z","event":"autonomy.gate.deploy_blocked","actor":"run-pipeline","detail":{"proposal":"p2","autonomy_mode":"steward_mode","review_mode":"full_review","reason":"full_review_human_approval_required"}}
EOF
DAEMON3=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__daemon")
if echo "$DAEMON3" | jq -e '.autonomy.mode == "auto_mode" and .autonomy.auto == true and (.autonomy.evidence.clean_streak == 22)' >/dev/null 2>&1; then
    pass "/__daemon exposes the autonomy contract mode + evidence"
else
    fail "/__daemon autonomy malformed: $DAEMON3"
fi
if echo "$DAEMON3" | jq -e '(.autonomyHistory | length) == 2 and .autonomyHistory[1].transition == "granted" and .autonomyHistory[1].mode == "auto_mode" and (.autonomyHistory[0].evidence.clean_streak == 5)' >/dev/null 2>&1; then
    pass "/__daemon exposes the autonomy contract history (2 snapshots, granted transition)"
else
    fail "/__daemon autonomyHistory malformed: $DAEMON3"
fi
if echo "$DAEMON3" | jq -e '(.provenanceEvents | length) == 3 and .provenanceEvents[0].event == "autonomy.mode.decided" and .provenanceEvents[1].event == "autonomy.gate.deferred" and .provenanceEvents[2].event == "autonomy.gate.deploy_blocked" and .provenanceEvents[2].detail.reason == "full_review_human_approval_required"' >/dev/null 2>&1; then
    pass "/__daemon exposes the autonomy gate provenance (3 events, oldest first)"
else
    fail "/__daemon provenanceEvents malformed: $DAEMON3"
fi
# Deferral alert: when the weekly cycle defers, the tick writes the
# last-deferral.json marker and /__daemon must surface it so the status bar
# can tell the steward the cycle waited instead of silently no-op'ing.
cat > "$TEST_WORKSPACE/memory/self-mod/last-deferral.json" << 'EOF'
{"deferred":true,"at":"2026-08-08T10:00:00Z","autonomy_mode":"steward_mode","review_mode":"full_review","reason":"steward_full_review_deferred"}
EOF
DAEMON4=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/__daemon")
if echo "$DAEMON4" | jq -e '.lastDeferral.deferred == true and .lastDeferral.autonomy_mode == "steward_mode" and .lastDeferral.review_mode == "full_review"' >/dev/null 2>&1; then
    pass "/__daemon exposes the deferral marker (cycle waited for the human)"
else
    fail "/__daemon lastDeferral malformed: $DAEMON4"
fi
rm -f "$TEST_WORKSPACE/memory/self-mod/last-deferral.json"

# The status bar + regenerate button must be part of the REBUILT dashboard
# (regenerate rebuilds via the shared builder — the minimal fixture page had
# no status bar, so this must be checked after the rebuild, not on the first
# fixture response).
BODY2=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/brain-dashboard.html")
if [[ "$BODY2" == *'id="statusDot"'* ]] && [[ "$BODY2" == *'id="regenBtn"'* ]]; then
    pass "rebuilt dashboard carries live status bar + regenerate button"
else
    fail "rebuilt dashboard missing status bar or regenerate button"
fi
if [[ "$BODY2" == *'id="statusSpark"'* ]] && [[ "$BODY2" == *'renderJobSparkline'* ]]; then
    pass "rebuilt dashboard carries the daemon-health sparkline"
else
    fail "rebuilt dashboard missing the daemon-health sparkline"
fi
if [[ "$BODY2" == *'id="statusAuto"'* ]] && [[ "$BODY2" == *'autonomy-pill'* ]]; then
    pass "rebuilt dashboard carries the autonomy pill"
else
    fail "rebuilt dashboard missing the autonomy pill"
fi
# The 🩺 tab's autonomy contract timeline (granted/revoked transitions) must
# be part of the rebuilt dashboard — the verification fragment's card.
if [[ "$BODY2" == *'Autonomy Contract · History'* ]] && [[ "$BODY2" == *'vAutoHist'* ]] && [[ "$BODY2" == *'renderAutoHist'* ]]; then
    pass "rebuilt dashboard carries the autonomy contract history timeline card"
else
    fail "rebuilt dashboard missing the autonomy history timeline card"
fi
# The 🛠 tab's gate provenance timeline (deferred / blocked / allowed /
# mode.decided) must be part of the rebuilt dashboard — the self-mod fragment's
# card, rendered from the same events.jsonl ledger.
if [[ "$BODY2" == *'Autonomy Gate · Provenance'* ]] && [[ "$BODY2" == *'smProvTimeline'* ]] && [[ "$BODY2" == *'renderProv'* ]]; then
    pass "rebuilt dashboard carries the autonomy gate provenance timeline card"
else
    fail "rebuilt dashboard missing the gate provenance timeline card"
fi
# The deferral alert must be part of the rebuilt status bar (id=statusDefer,
# driven by /__daemon's lastDeferral in pollStatus).
if [[ "$BODY2" == *'id="statusDefer"'* ]] && [[ "$BODY2" == *'d.lastDeferral'* ]]; then
    pass "rebuilt dashboard carries the deferral alert pill"
else
    fail "rebuilt dashboard missing the deferral alert pill"
fi
rm -f "$TEST_WORKSPACE/memory/self-mod/autonomy-state.json" "$TEST_WORKSPACE/memory/self-mod/autonomy-history.jsonl" "$TEST_WORKSPACE/memory/provenance/events.jsonl"

# ── Test 7: status / stop lifecycle ─────────────────────────────────────
echo "Test 7: status and stop lifecycle"

if "$ROOT/scripts/serve-dashboard.sh" status >/dev/null 2>&1; then
    pass "status reports running while server is up"
else
    fail "status should report running"
fi

STOP_OUT=$("$ROOT/scripts/serve-dashboard.sh" stop 2>&1)
SERVER_PID=""  # launcher stop owns the process now
if "$ROOT/scripts/serve-dashboard.sh" status >/dev/null 2>&1; then
    fail "status should report stopped after stop (out: $STOP_OUT)"
else
    pass "status reports stopped after stop"
fi

# ── Test 8: self-heal — start rebuilds a missing dashboard ─────────────
echo "Test 8: start self-heals a missing brain-dashboard.html"

rm -f "$TEST_WORKSPACE/brain-dashboard.html"
HEAL_OUT=$("$ROOT/scripts/serve-dashboard.sh" start 2>&1) || {
    fail "start should self-heal a missing dashboard: $HEAL_OUT"
    true
}
if [ -f "$DASHBOARD_PID_FILE" ]; then
    SERVER_PID=$(cat "$DASHBOARD_PID_FILE")
fi
HEAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/brain-dashboard.html")
if [ "$HEAL_CODE" = "200" ] && [ -s "$TEST_WORKSPACE/brain-dashboard.html" ]; then
    pass "missing dashboard rebuilt and served (HTTP $HEAL_CODE)"
else
    fail "self-heal failed — HTTP $HEAL_CODE, file $( [ -s "$TEST_WORKSPACE/brain-dashboard.html" ] && echo present || echo absent )"
fi

# Clean up the self-healed server before summary.
"$ROOT/scripts/serve-dashboard.sh" stop >/dev/null 2>&1 || true
SERVER_PID=""

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Dashboard Serve Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
