#!/bin/bash
# test_workspace_broadcast.sh — A2: global workspace of attention.
#
# Tests:
#  1. broadcast.sh appends currentFocus + a recentBroadcasts entry
#  2. recentBroadcasts ring caps at 5 entries
#  3. workspace-refresh.sh assembles the context block (phase, goals, neuromod)
#  4. workspace-refresh.sh survives a missing neuromod vector (neutral snapshot)
#  5. atomic write hygiene (no tmp residue, lock present)
#
# Run: bash tests/test_workspace_broadcast.sh
# Requires: jq, bc

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

BC="$ROOT/skills/thalamus-memory/scripts/broadcast.sh"
RF="$ROOT/skills/thalamus-memory/scripts/workspace-refresh.sh"

# ── Test 1: broadcast writes currentFocus + entry ──────────────────────
echo "Test 1: broadcast.sh appends currentFocus and a broadcast entry"

"$BC" --source "amygdala-memory" --signal "positive_state" \
      --action "pass" --gate-score 0.55 > /dev/null 2>&1

WS="$TEST_WORKSPACE/memory/workspace.json"
if [[ -f "$WS" ]]; then
    FOCUS=$(jq -r '.currentFocus.source' "$WS")
    N=$(jq '.recentBroadcasts | length' "$WS")
    if [[ "$FOCUS" = "amygdala-memory" && "$N" -ge 1 ]]; then
        pass "broadcast set currentFocus and appended an entry (n=$N)"
    else
        fail "broadcast output wrong: focus=$FOCUS n=$N"
    fi
else
    fail "workspace.json not created by broadcast.sh"
fi

# ── Test 2: ring caps at 5 ─────────────────────────────────────────────
echo "Test 2: recentBroadcasts ring caps at 5"

for i in 1 2 3 4 5 6 7; do
    "$BC" --source "src-$i" --signal "sig-$i" --action "pass" \
          --gate-score "0.$i" > /dev/null 2>&1 || true
done
N=$(jq '.recentBroadcasts | length' "$WS")
if [[ "$N" -eq 5 ]]; then
    pass "ring capped at 5 (got $N)"
else
    fail "ring should cap at 5, got $N"
fi
HEAD=$(jq -r '.recentBroadcasts[0].source' "$WS")
if [[ "$HEAD" = "src-7" ]]; then
    pass "most recent broadcast is first"
else
    fail "most recent should be src-7, got $HEAD"
fi

# ── Test 3: workspace-refresh assembles context ────────────────────────
echo "Test 3: workspace-refresh.sh assembles the context block"

cat > "$TEST_WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}]}
EOF
cat > "$TEST_WORKSPACE/memory/thalamus-state.json" << 'EOF'
{"attentionFocus": ["ship the brain suite"], "lastGateRun": "2026-08-08T00:00:00Z"}
EOF

"$RF" > /dev/null 2>&1

if jq -e '.context.phase and (.context.goals | length > 0) and .context.neuromod' "$WS" > /dev/null 2>&1; then
    pass "context block has phase, goals, neuromod snapshot"
else
    fail "context block incomplete: $(cat "$WS")"
fi

# ── Test 4: refresh survives missing neuromod ──────────────────────────
echo "Test 4: workspace-refresh survives a missing neuromod vector"

rm -f "$TEST_WORKSPACE/memory/neuromod-state.json"
if "$RF" > /dev/null 2>&1; then
    NEURO=$(jq -r '.context.neuromod // "missing"' "$WS" 2>/dev/null || echo "missing")
    if [[ "$NEURO" != "missing" ]]; then
        pass "refresh wrote a neutral neuromod snapshot when vector absent"
    else
        pass "refresh tolerated missing vector (no context.neuromod, exit 0)"
    fi
else
    fail "workspace-refresh.sh should exit 0 with a missing neuromod vector"
fi

# ── Test 5: atomic write hygiene ───────────────────────────────────────
echo "Test 5: atomic write hygiene"

"$BC" --source "amygdala-memory" --signal "positive_state" --action "pass" \
      --gate-score 0.55 > /dev/null 2>&1 || true
if [[ -f "$TEST_WORKSPACE/memory/workspace.json.lock" ]]; then
    pass "workspace lock file present"
else
    fail "workspace lock file missing"
fi
if ! ls "$TEST_WORKSPACE/memory/workspace.json.tmp."* > /dev/null 2>&1; then
    pass "no tmp residue"
else
    fail "tmp residue left behind"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Workspace/Broadcast Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0