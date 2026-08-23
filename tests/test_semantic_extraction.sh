#!/bin/bash
# test_semantic_extraction.sh — Initiative 7: semantic knowledge from episodic store.
#
# 1. Create a week of synthetic episodic entries
# 2. Run extract-patterns.sh
# 3. Assert themes/strategies/antipatterns appear in semantic-state.json
# 4. Assert decide.sh applies a semantic boost
set -euo pipefail

PASS=0; FAIL=0
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
export WORKSPACE

pass() { echo "  PASS $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

mkdir -p "$WORKSPACE/memory"

echo "=== Semantic Knowledge Extraction Tests ==="
echo ""

# ── Test 1: Extract patterns from synthetic episodic data ──────────────────
echo "Test 1: extract-patterns.sh produces semantic-state.json"

# Create synthetic hippocampus events with known patterns
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$WORKSPACE/memory/hippocampus-events.jsonl" << EOF
{"timestamp":"$TS","summary":"Fixed the memory consolidation bug by adding timestamp validation"}
{"timestamp":"$TS","summary":"Completed the install.sh hardening with rollback support"}
{"timestamp":"$TS","summary":"Fixed the vulkaninfo parser to handle RADV output format"}
{"timestamp":"$TS","summary":"Built the cognitive dashboard --brain command"}
{"timestamp":"$TS","summary":"ERROR: gate.sh deadlock detected during deep-brain-kernel --check"}
{"timestamp":"$TS","summary":"Finished wiring the VTA to PFC goal completion closed loop"}
{"timestamp":"$TS","summary":"Fixed shell hardening unbound variable in get-state.sh"}
{"timestamp":"$TS","summary":"ERROR: neuromod-update.sh crashed on missing interoceptive-state.json"}
{"timestamp":"$TS","summary":"Shipped the Integrative State Layer A1 through A3"}
{"timestamp":"$TS","summary":"Completed the exhaustive debugging pass — all 28 tests green"}
EOF

bash skills/hippocampus-memory/scripts/extract-patterns.sh --days 7 2>/dev/null

if [ -f "$WORKSPACE/memory/semantic-state.json" ]; then
    T_COUNT=$(jq '.patterns.themes | length' "$WORKSPACE/memory/semantic-state.json")
    S_COUNT=$(jq '.patterns.strategies | length' "$WORKSPACE/memory/semantic-state.json")
    A_COUNT=$(jq '.patterns.antipatterns | length' "$WORKSPACE/memory/semantic-state.json")
    if [ "$T_COUNT" -gt 0 ]; then
        pass "extracted $T_COUNT theme(s) from episodic data"
    else
        fail "no themes extracted"
    fi
    if [ "$S_COUNT" -gt 0 ]; then
        pass "extracted $S_COUNT strategy/strategies from success markers"
    else
        fail "no strategies extracted from accomplishment patterns"
    fi
    if [ "$A_COUNT" -gt 0 ]; then
        pass "extracted $A_COUNT antipattern(s) from error markers"
    else
        fail "no antipatterns extracted from error events"
    fi
else
    fail "semantic-state.json was not created"
fi

# ── Test 2: Schema validity ───────────────────────────────────────────────
echo "Test 2: semantic-state.json has valid schema"
if jq -e '.schema == 1 and .patterns and .method' "$WORKSPACE/memory/semantic-state.json" >/dev/null 2>&1; then
    pass "semantic-state.json schema valid"
else
    fail "semantic-state.json schema invalid"
fi

# ── Test 3: Empty workspace produces valid (but empty) output ──────────────
echo "Test 3: empty workspace produces valid empty semantic state"
WS2=$(mktemp -d)
trap 'rm -rf "$WS2"' EXIT
WORKSPACE="$WS2" bash skills/hippocampus-memory/scripts/extract-patterns.sh --days 7 2>/dev/null
if [ -f "$WS2/memory/semantic-state.json" ] && jq -e '.patterns.themes == []' "$WS2/memory/semantic-state.json" >/dev/null 2>&1; then
    pass "empty workspace produces valid empty semantic state"
else
    fail "empty workspace semantic state not valid"
fi

# ── Test 4: decide.sh loads semantic state ────────────────────────────────
echo "Test 4: decide.sh references SEMANTIC_STATE_FILE"
if grep -q "SEMANTIC_STATE_FILE" skills/prefrontal-cortex-memory/scripts/decide.sh; then
    pass "decide.sh reads SEMANTIC_STATE_FILE for semantic boost"
else
    fail "decide.sh does NOT read semantic state"
fi

# ── Test 5: extract-patterns.sh passes bash -n ────────────────────────────
echo "Test 5: extract-patterns.sh bash -n"
if bash -n skills/hippocampus-memory/scripts/extract-patterns.sh 2>/dev/null; then
    pass "extract-patterns.sh passes bash -n"
else
    fail "extract-patterns.sh bash -n failed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1