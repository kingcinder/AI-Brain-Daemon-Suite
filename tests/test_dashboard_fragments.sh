#!/bin/bash
# test_dashboard_fragments.sh — Unit tests for the executive-function,
# self-mod-runner, and thalamus-memory dashboard fragments.
#
# Tests:
#  1. Each of the three skills' generate-dashboard.sh writes a well-formed
#     fragment {id, order, label, icon, html, script, data} even with NO state
#     files present (the tab must always appear).
#  2. With fixture state files, the fragments carry the expected data (exec
#     load E, self-mod streak, thalamus gate stats).
#  3. The shared dashboard-builder.sh assembles a page containing ALL known
#     tabs — the 11 registry skills + verification + the 3 new ones (15 total).
#  4. The served dashboard (via the serve-mode server) injects auto-refresh
#     and serves the 3 new fragments' content (integration with dashboard-server.py).
#
# Run: bash tests/test_dashboard_fragments.sh
# Requires: python3, jq, curl (all already in the Suite's dependency set)

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
SERVER_PID=""
PORT=""

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Pick a free port dynamically so parallel/local runs never collide.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

export WORKSPACE="$TEST_WORKSPACE"
export DASHBOARD_HOST="127.0.0.1"
export DASHBOARD_PORT="$PORT"
export DASHBOARD_PID_FILE="$TEST_WORKSPACE/.dashboard-server.pid"
export DASHBOARD_LOG="$TEST_WORKSPACE/.dashboard-server.log"

mkdir -p "$TEST_WORKSPACE/memory/dashboard-fragments" \
         "$TEST_WORKSPACE/memory/executive" \
         "$TEST_WORKSPACE/memory/self-mod"

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    "$ROOT/scripts/serve-dashboard.sh" stop >/dev/null 2>&1 || true
    rm -rf "$TEST_WORKSPACE"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── Test 1: fragments written even with no state ────────────────────────
echo "Test 1: all three generate-dashboard.sh write fragments with no state"

EXEC_OUT=$("$ROOT/skills/executive-function/scripts/generate-dashboard.sh" 2>&1) || true
SM_OUT=$("$ROOT/skills/self-mod-runner/scripts/generate-dashboard.sh" 2>&1) || true
TH_OUT=$("$ROOT/skills/thalamus-memory/scripts/generate-dashboard.sh" 2>&1) || true

OK_FRAGS=1
for pair in "executive.json executive" "self_mod.json self_mod" "thalamus.json thalamus"; do
    f="${pair%% *}"; id="${pair##* }"
    if [ ! -f "$TEST_WORKSPACE/memory/dashboard-fragments/$f" ]; then
        fail "fragment $f not written (no-state) — $EXEC_OUT $SM_OUT $TH_OUT"
        OK_FRAGS=0
        continue
    fi
    if jq -e --arg id "$id" '.id == $id and (.html | length) > 0 and (.script | length) > 0 and (.data | type) == "object" and (.label | length) > 0 and (.icon | length) > 0' "$TEST_WORKSPACE/memory/dashboard-fragments/$f" >/dev/null 2>&1; then
        pass "fragment $f well-formed with no state"
    else
        fail "fragment $f malformed: $(cat "$TEST_WORKSPACE/memory/dashboard-fragments/$f")"
        OK_FRAGS=0
    fi
done
[ "$OK_FRAGS" = "1" ] && pass "all three tabs appear even before any state exists" || true

# ── Test 2: fixture state flows into fragment data ──────────────────────
echo "Test 2: fixture state populates fragment data"

cat > "$TEST_WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.42, "G": 3, "Q": 1, "band": "desired", "load_reduction_recommended": false}
EOF
cat > "$TEST_WORKSPACE/memory/executive/last-cycle.json" << 'EOF'
{"last_cycle_utc": "2026-08-08T01:28:02Z", "phase": "2"}
EOF
cat > "$TEST_WORKSPACE/memory/self-mod/live-metrics.json" << 'EOF'
{"task_success": 0.85, "latency_norm": 0.9, "memory_kv_norm": 1.0}
EOF
cat > "$TEST_WORKSPACE/memory/self-mod/graduation-streak.json" << 'EOF'
{"clean_streak": 7, "clean_streak_target": 20, "review_mode": "full_review"}
EOF
# Autonomy gate provenance: seed the audit ledger (what log-provenance.sh
# event writes) so the fragment's baked timeline has real entries to render.
mkdir -p "$TEST_WORKSPACE/memory/provenance"
cat > "$TEST_WORKSPACE/memory/provenance/events.jsonl" << 'EOF'
{"ts":"2026-08-07T02:00:00Z","event":"autonomy.mode.decided","actor":"deep-brain-kernel","detail":{"mode":"steward_mode","auto":false,"transition":"initial","computed_at":"2026-08-07T02:00:00Z"}}
{"ts":"2026-08-08T02:00:00Z","event":"autonomy.gate.deferred","actor":"run-pipeline","detail":{"autonomy_mode":"steward_mode","review_mode":"full_review","reason":"steward_full_review_deferred"}}
{"ts":"2026-08-09T02:00:00Z","event":"autonomy.gate.deploy_allowed","actor":"run-pipeline","detail":{"proposal":"p3","autonomy_mode":"auto_mode","review_mode":"full_review","reason":"autonomy_gate_passed"}}
EOF
mkdir -p "$TEST_WORKSPACE/memory/self-mod/proposals" "$TEST_WORKSPACE/memory/self-mod/deploys" "$TEST_WORKSPACE/memory/self-mod/pipeline-runs"
touch "$TEST_WORKSPACE/memory/self-mod/proposals/p1.json" "$TEST_WORKSPACE/memory/self-mod/proposals/p2.json"
touch "$TEST_WORKSPACE/memory/self-mod/deploys/d1.json"
cat > "$TEST_WORKSPACE/memory/thalamus-state.json" << 'EOF'
{"stats": {"totalSignalsProcessed": 47, "amplified": 12, "passed": 22, "attenuated": 8, "suppressed": 5, "dispatchedToTargets": 42}, "attentionFocus": ["goal_shipping"], "suppressedQueue": [{"signal": {"source": "amygdala-memory", "signal": "positive_state"}}], "gateSensitivity": 0.5, "lastGateRun": "2026-08-08T07:00:00Z"}
EOF

"$ROOT/skills/executive-function/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
"$ROOT/skills/self-mod-runner/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
"$ROOT/skills/thalamus-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true

E_VAL=$(jq -r '.data.E' "$TEST_WORKSPACE/memory/dashboard-fragments/executive.json")
STREAK=$(jq -r '.data.streak' "$TEST_WORKSPACE/memory/dashboard-fragments/self_mod.json")
PROPOSALS=$(jq -r '.data.proposals' "$TEST_WORKSPACE/memory/dashboard-fragments/self_mod.json")
TH_TOTAL=$(jq -r '.data.total' "$TEST_WORKSPACE/memory/dashboard-fragments/thalamus.json")
TH_FOCUS=$(jq -r '.data.focus[0]' "$TEST_WORKSPACE/memory/dashboard-fragments/thalamus.json")

if [ "$E_VAL" = "0.42" ]; then pass "executive fragment carries E=0.42"; else fail "executive E=$E_VAL (want 0.42)"; fi
if [ "$STREAK" = "7" ] && [ "$PROPOSALS" = "2" ]; then pass "self-mod fragment carries streak=7, proposals=2"; else fail "self-mod streak=$STREAK proposals=$PROPOSALS"; fi
if [ "$TH_TOTAL" = "47" ] && [ "$TH_FOCUS" = "goal_shipping" ]; then pass "thalamus fragment carries total=47, focus=goal_shipping"; else fail "thalamus total=$TH_TOTAL focus=$TH_FOCUS"; fi

# The 🛠 self-mod fragment must bake the gate provenance timeline: the last
# autonomy.* events from memory/provenance/events.jsonl (oldest first) and the
# card markup + renderer that draws the steward's gate history.
if jq -e '(.data.provenanceEvents | type) == "array" and (.data.provenanceEvents | length) == 3 and .data.provenanceEvents[0].event == "autonomy.mode.decided" and .data.provenanceEvents[2].event == "autonomy.gate.deploy_allowed"' "$TEST_WORKSPACE/memory/dashboard-fragments/self_mod.json" >/dev/null 2>&1; then
    pass "self-mod fragment bakes 3 gate provenance events (oldest first)"
else
    fail "self-mod provenanceEvents malformed: $(jq -c '.data.provenanceEvents' "$TEST_WORKSPACE/memory/dashboard-fragments/self_mod.json")"
fi
if jq -e '.html | contains("Autonomy Gate · Provenance") and contains("smProvTimeline")' "$TEST_WORKSPACE/memory/dashboard-fragments/self_mod.json" >/dev/null 2>&1; then
    pass "self-mod fragment carries the Autonomy Gate · Provenance timeline card"
else
    fail "self-mod fragment missing the gate provenance timeline card"
fi
if jq -e '.script | contains("renderProv") and contains("provenanceEvents")' "$TEST_WORKSPACE/memory/dashboard-fragments/self_mod.json" >/dev/null 2>&1; then
    pass "self-mod fragment renderer wired to provenanceEvents"
else
    fail "self-mod fragment renderer missing"
fi

# ── Test 3: builder assembles all 15 tabs ───────────────────────────────
echo "Test 3: dashboard-builder assembles all 15 tabs"

# verification is NOT in the builder's REGISTRY — its tab appears only when
# verification.json exists. Generate it from a fixture so all 15 skill
# packages are genuinely asserted (this mirrors the live workspace, where
# the verification sweep has run).
cat > "$TEST_WORKSPACE/memory/verification-state.json" << 'EOF'
{"lastRun": "2026-08-08T07:00:00Z", "totals": {"tests": 21, "passed": 21, "failed": 0}, "lastFailure": []}
EOF
"$ROOT/skills/verification-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true

# The 🩺 verification fragment must carry the autonomy contract history card
# (the timeline the steward reads to see when/why auto_mode was granted or
# revoked). The card is always present; the data array defaults to [] with no
# ledger, and the served page live-refreshes it from /__daemon.
if jq -e '.html | contains("Autonomy Contract · History")' "$TEST_WORKSPACE/memory/dashboard-fragments/verification.json" >/dev/null 2>&1; then
    pass "verification fragment carries the autonomy contract history card"
else
    fail "verification fragment missing the autonomy history card"
fi
if jq -e '(.data.autonomyHistory | type) == "array"' "$TEST_WORKSPACE/memory/dashboard-fragments/verification.json" >/dev/null 2>&1; then
    pass "verification fragment bakes autonomyHistory data (defaults to [])"
else
    fail "verification fragment autonomyHistory data malformed"
fi

# Fresh build via the canonical builder (no --focus → deterministic order).
"$ROOT/skills/cerebellum-memory/scripts/dashboard-builder.sh" >/dev/null 2>&1 || true

TABS=$(grep -o 'data-tab="[a-z_]*"' "$TEST_WORKSPACE/brain-dashboard.html" | sed 's/data-tab="//;s/"//' | sort -u)
TAB_COUNT=$(echo "$TABS" | wc -l)
EXPECTED="acc_conflict acc_error amygdala basal cerebellum executive heartbeat hippocampus insula prefrontal self_mod social thalamus verification vta"
# Compare as sorted line-sets (avoids trailing-space/echo pitfalls).
GOT_SET=$(echo "$TABS" | sort)
WANT_SET=$(printf '%s\n' $EXPECTED | sort)
if [ "$GOT_SET" = "$WANT_SET" ]; then
    pass "all 15 tabs present in dashboard ($TAB_COUNT)"
else
    fail "tab set mismatch — got [$TABS], want [$EXPECTED]"
fi

# ── Test 4: serve-mode serves the new tabs with auto-refresh ────────────
echo "Test 4: serve-mode serves the assembled dashboard with auto-refresh"

"$ROOT/scripts/serve-dashboard.sh" start >/dev/null 2>&1
if [ -f "$DASHBOARD_PID_FILE" ]; then
    SERVER_PID=$(cat "$DASHBOARD_PID_FILE")
fi
BODY=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/brain-dashboard.html" || true)
# NOTE: use bash-native substring matching, NOT `echo "$BODY" | grep -q`.
# Under `set -o pipefail`, grep -q exits as soon as it finds a match (the tab
# buttons are near the top of the HTML), the echo gets SIGPIPE while still
# writing the rest of the ~38KB body, and pipefail turns that into a false
# "missing" failure — the intermittent flake this test used to have.
if [[ "$BODY" == *'data-tab="executive"'* ]] && [[ "$BODY" == *'data-tab="self_mod"'* ]] && [[ "$BODY" == *'data-tab="thalamus"'* ]]; then
    pass "served page contains the three new tabs"
else
    fail "served page missing new tabs"
fi
if [[ "$BODY" == *__dashboard_mtime* ]]; then
    pass "served page carries auto-refresh poller"
else
    fail "served page missing auto-refresh"
fi

"$ROOT/scripts/serve-dashboard.sh" stop >/dev/null 2>&1 || true
SERVER_PID=""

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Dashboard Fragment Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
