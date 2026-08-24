#!/bin/bash
# test_cognitive_tools.sh — End-to-end tests for the 5 new agent-loop tools:
# read_working_memory, write_working_memory, get_metacognition, get_emotional_state,
# get_social_context
#
# Exercises each tool through the tools.sh registry (sourced directly)
# using a stub WORKSPACE with fixture data. Validates JSON output structure,
# working memory persistence across calls, and metacognition confidence scaling.

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

TOOLS="$ROOT/core/agent-loop/tools.sh"
# Stub AGENT_ROOT for tools that need it
export AGENT_ROOT="$ROOT"

# Helper: source tools.sh and call a tool, capturing output
call_tool() {
  local name="$1" args="${2:-{}}"
  bash -c "source '$TOOLS'; agent_tool_run '$name' '$args'" 2>/dev/null
}

# ── Fixture data ────────────────────────────────────────────────────────
mkdir -p "$WS/memory"

# PFC state (for get_metacognition → active goals)
cat > "$WS/memory/pfc-state.json" << 'EOF'
{
  "goals": [
    {"description": "Improve encoding throughput", "priority": 0.8, "status": "active"},
    {"description": "Fix heartbeat reliability", "priority": 0.6, "status": "active"}
  ]
}
EOF

# Conflict state (for get_metacognition → conflict load)
cat > "$WS/memory/conflict-state.json" << 'EOF'
{
  "conflictLoad": 0.7,
  "activeConflicts": [{"id": "c1"}],
  "attentionFlags": [{"id": "f1"}, {"id": "f2"}]
}
EOF

# Executive load (for get_metacognition → E value)
cat > "$WS/memory/executive-load.json" << 'EOF'
{
  "E": 0.45,
  "band": "desired",
  "G": 2,
  "Q": 1,
  "I_sec": 5.2
}
EOF

# Daemon state (for get_metacognition → error history)
cat > "$WS/memory/deep-brain-kernel-state.json" << 'EOF'
{
  "jobStats": {
    "heartbeat_beat": {"success": 100, "failure": 2, "consecutive_failures": 0},
    "thalamus_gate": {"success": 50, "failure": 5, "consecutive_failures": 0}
  }
}
EOF

# Interoceptive state (for get_emotional_state)
cat > "$WS/memory/interoceptive-state.json" << 'EOF'
{
  "gutSignal": -0.52,
  "cognitiveLoad": 0.30,
  "friction": 0.57,
  "selfCoherence": 0.70,
  "channels": {"pain": 0.1, "pleasure": 0.8, "temperature": 0.5}
}
EOF

# Social relationships (for get_social_context)
cat > "$WS/memory/social-relationships.json" << 'EOF'
{
  "relationships": [
    {"name": "Alice", "trust": 0.9, "lastInteraction": "2026-08-23T10:00:00Z", "interactionFrequency": "daily"},
    {"name": "Bob", "trust": 0.4, "lastInteraction": "2026-08-20T15:30:00Z", "interactionFrequency": "weekly"},
    {"name": "Charlie", "trust": 0.7, "lastInteraction": "2026-08-22T08:00:00Z", "interactionFrequency": "daily"}
  ]
}
EOF

# ── Tests ───────────────────────────────────────────────────────────────

# 1. write_working_memory — basic write
section "write_working_memory"
OUT=$(call_tool "write_working_memory" '{"content":"I am debugging the encoding pipeline. Found that Carnice 35B uses reasoning steps."}')
if echo "$OUT" | jq -e '.written == true' >/dev/null 2>&1; then
  pass "write_working_memory returns {written:true}"
else
  fail "write_working_memory did not return {written:true}: $OUT"
fi

# Verify file was created
if [ -f "$WS/memory/working-memory.json" ]; then
  pass "working-memory.json created on disk"
else
  fail "working-memory.json not found on disk"
fi

# Verify content and updatedAt fields
CONTENT=$(jq -r '.content' "$WS/memory/working-memory.json" 2>/dev/null)
if echo "$CONTENT" | grep -q "Carnice 35B"; then
  pass "working memory content preserved correctly"
else
  fail "working memory content mismatch: $CONTENT"
fi

if jq -e '.updatedAt' "$WS/memory/working-memory.json" >/dev/null 2>&1; then
  pass "working memory has updatedAt timestamp"
else
  fail "working memory missing updatedAt"
fi

# 2. read_working_memory — read back
section "read_working_memory"
OUT=$(call_tool "read_working_memory")
if echo "$OUT" | grep -q "Carnice 35B"; then
  pass "read_working_memory returns the written content"
else
  fail "read_working_memory content mismatch: $OUT"
fi

# 3. write_working_memory — overwrite (persistence across calls)
section "write_working_memory (overwrite)"
OUT=$(call_tool "write_working_memory" '{"content":"Updated context: encoding pipeline completed successfully."}')
if echo "$OUT" | jq -e '.written == true' >/dev/null 2>&1; then
  pass "overwrite succeeded"
else
  fail "overwrite failed: $OUT"
fi

OUT2=$(call_tool "read_working_memory")
if echo "$OUT2" | grep -q "encoding pipeline completed"; then
  pass "read_working_memory returns updated content (overwrite persisted)"
else
  fail "overwrite did not persist: $OUT2"
fi

# 4. write_working_memory — empty content rejected
section "write_working_memory (edge cases)"
OUT=$(call_tool "write_working_memory" '{"content":""}')
if echo "$OUT" | jq -e '.error' >/dev/null 2>&1; then
  pass "empty content rejected with error"
else
  fail "empty content was not rejected: $OUT"
fi

# 5. write_working_memory — missing content field
OUT=$(call_tool "write_working_memory" '{}')
if echo "$OUT" | jq -e '.error' >/dev/null 2>&1; then
  pass "missing content field rejected with error"
else
  fail "missing content was not rejected: $OUT"
fi

# 6. read_working_memory — no file yet (clean workspace)
section "read_working_memory (empty)"
CLEAN_WS=$(mktemp -d)
mkdir -p "$CLEAN_WS/memory"
OUT=$(WORKSPACE="$CLEAN_WS" bash -c "source '$TOOLS'; agent_tool_run read_working_memory '{}'" 2>/dev/null)
rm -rf "$CLEAN_WS"
if echo "$OUT" | jq -e '.note' >/dev/null 2>&1; then
  pass "read_working_memory handles missing file gracefully"
else
  fail "read_working_memory did not handle missing file: $OUT"
fi

# 7. get_metacognition — full context
section "get_metacognition"
OUT=$(call_tool "get_metacognition")
if echo "$OUT" | jq -e '.confidence' >/dev/null 2>&1; then
  pass "get_metacognition returns confidence field"
else
  fail "get_metacognition missing confidence: $OUT"
fi

if echo "$OUT" | jq -e '.conflictLoad == 0.7' >/dev/null 2>&1; then
  pass "get_metacognition reports correct conflictLoad (0.7)"
else
  fail "conflictLoad mismatch: $OUT"
fi

if echo "$OUT" | jq -e '.executiveLoad == 0.45' >/dev/null 2>&1; then
  pass "get_metacognition reports correct executiveLoad (0.45)"
else
  fail "executiveLoad mismatch: $OUT"
fi

# Verify confidence is a number between 0 and 1
CONF=$(echo "$OUT" | jq -r '.confidence')
if python3 -c "import sys; c=float('$CONF'); sys.exit(0 if 0 <= c <= 1 else 1)" 2>/dev/null; then
  pass "confidence ($CONF) is in valid range [0, 1]"
else
  fail "confidence ($CONF) out of range"
fi

# 8. get_metacognition — confidence scaling (high conflict → lower confidence)
section "get_metacognition (scaling)"
# High conflict + high load should produce lower confidence
cat > "$WS/memory/conflict-state.json" << 'EOF'
{"conflictLoad": 0.95, "activeConflicts": [{"id":"c1"},{"id":"c2"},{"id":"c3"}], "attentionFlags": []}
EOF
cat > "$WS/memory/executive-load.json" << 'EOF'
{"E": 0.85, "band": "hard_ceiling_zone", "G": 3, "Q": 5, "I_sec": 20.0}
EOF
cat > "$WS/memory/deep-brain-kernel-state.json" << 'EOF'
{"jobStats": {"heartbeat_beat": {"success": 10, "failure": 20, "consecutive_failures": 5}}}
EOF

OUT_HIGH=$(call_tool "get_metacognition")
CONF_HIGH=$(echo "$OUT_HIGH" | jq -r '.confidence')

# Restore normal fixtures
cat > "$WS/memory/conflict-state.json" << 'EOF'
{"conflictLoad": 0.7, "activeConflicts": [{"id":"c1"}], "attentionFlags": [{"id":"f1"},{"id":"f2"}]}
EOF
cat > "$WS/memory/executive-load.json" << 'EOF'
{"E": 0.45, "band": "desired", "G": 2, "Q": 1, "I_sec": 5.2}
EOF
cat > "$WS/memory/deep-brain-kernel-state.json" << 'EOF'
{"jobStats": {"heartbeat_beat": {"success": 100, "failure": 2, "consecutive_failures": 0}, "thalamus_gate": {"success": 50, "failure": 5, "consecutive_failures": 0}}}
EOF

OUT_LOW=$(call_tool "get_metacognition")
CONF_LOW=$(echo "$OUT_LOW" | jq -r '.confidence')

if python3 -c "import sys; sys.exit(0 if float('$CONF_HIGH') < float('$CONF_LOW') else 1)" 2>/dev/null; then
  pass "high conflict/load ($CONF_HIGH) produces lower confidence than normal ($CONF_LOW)"
else
  fail "confidence did not scale correctly: high=$CONF_HIGH low=$CONF_LOW"
fi

# 9. get_metacognition — missing files (graceful degradation)
section "get_metacognition (missing files)"
CLEAN_WS=$(mktemp -d)
mkdir -p "$CLEAN_WS/memory"
OUT=$(WORKSPACE="$CLEAN_WS" bash -c "source '$TOOLS'; agent_tool_run get_metacognition '{}'" 2>/dev/null)
rm -rf "$CLEAN_WS"
if echo "$OUT" | jq -e '.confidence' >/dev/null 2>&1; then
  pass "get_metacognition handles missing files gracefully (returns default)"
else
  fail "get_metacognition did not handle missing files: $OUT"
fi

# 10. get_emotional_state — reads interoceptive state
section "get_emotional_state"
OUT=$(call_tool "get_emotional_state")
if echo "$OUT" | jq -e '.gutSignal == -0.52' >/dev/null 2>&1; then
  pass "get_emotional_state reports correct gutSignal (-0.52)"
else
  fail "gutSignal mismatch: $OUT"
fi

if echo "$OUT" | jq -e '.cognitiveLoad == 0.30' >/dev/null 2>&1; then
  pass "get_emotional_state reports correct cognitiveLoad (0.30)"
else
  fail "cognitiveLoad mismatch: $OUT"
fi

if echo "$OUT" | jq -e '.friction == 0.57' >/dev/null 2>&1; then
  pass "get_emotional_state reports correct friction (0.57)"
else
  fail "friction mismatch: $OUT"
fi

if echo "$OUT" | jq -e '.selfCoherence == 0.70' >/dev/null 2>&1; then
  pass "get_emotional_state reports correct selfCoherence (0.70)"
else
  fail "selfCoherence mismatch: $OUT"
fi

if echo "$OUT" | jq -e '.channels.pain == 0.1' >/dev/null 2>&1; then
  pass "get_emotional_state reports channels (pain=0.1)"
else
  fail "channels mismatch: $OUT"
fi

# 11. get_emotional_state — missing file
section "get_emotional_state (missing)"
CLEAN_WS=$(mktemp -d)
mkdir -p "$CLEAN_WS/memory"
OUT=$(WORKSPACE="$CLEAN_WS" bash -c "source '$TOOLS'; agent_tool_run get_emotional_state '{}'" 2>/dev/null)
rm -rf "$CLEAN_WS"
if echo "$OUT" | jq -e '.note' >/dev/null 2>&1; then
  pass "get_emotional_state handles missing file gracefully"
else
  fail "get_emotional_state did not handle missing file: $OUT"
fi

# 12. get_social_context — reads relationships
section "get_social_context"
OUT=$(call_tool "get_social_context")
if echo "$OUT" | jq -e '.relationships | length == 3' >/dev/null 2>&1; then
  pass "get_social_context returns 3 relationships"
else
  fail "relationship count mismatch: $OUT"
fi

# Check first relationship (Alice, trust 0.9)
ALICE_TRUST=$(echo "$OUT" | jq -r '.relationships[0].trust')
if [ "$ALICE_TRUST" = "0.9" ]; then
  pass "get_social_context reports Alice trust=0.9"
else
  fail "Alice trust mismatch: $ALICE_TRUST"
fi

ALICE_FREQ=$(echo "$OUT" | jq -r '.relationships[0].frequency')
if [ "$ALICE_FREQ" = "daily" ]; then
  pass "get_social_context reports Alice frequency=daily"
else
  fail "Alice frequency mismatch: $ALICE_FREQ"
fi

# 13. get_social_context — missing file
section "get_social_context (missing)"
CLEAN_WS=$(mktemp -d)
mkdir -p "$CLEAN_WS/memory"
OUT=$(WORKSPACE="$CLEAN_WS" bash -c "source '$TOOLS'; agent_tool_run get_social_context '{}'" 2>/dev/null)
rm -rf "$CLEAN_WS"
if echo "$OUT" | jq -e '.note' >/dev/null 2>&1; then
  pass "get_social_context handles missing file gracefully"
else
  fail "get_social_context did not handle missing file: $OUT"
fi

# 14. Tool registry — all 5 new tools are registered
section "tool registry"
NAMES=$(bash -c "source '$TOOLS'; echo \$AGENT_TOOL_NAMES" 2>/dev/null)
for tool in read_working_memory write_working_memory get_metacognition get_emotional_state get_social_context; do
  if echo "$NAMES" | grep -qw "$tool"; then
    pass "$tool is registered in AGENT_TOOL_NAMES"
  else
    fail "$tool is NOT registered in AGENT_TOOL_NAMES"
  fi
done

# 15. Tool registry — descriptions include all 5 new tools
DESC=$(bash -c "source '$TOOLS'; agent_tool_descriptions" 2>/dev/null)
for tool in read_working_memory write_working_memory get_metacognition get_emotional_state get_social_context; do
  if echo "$DESC" | grep -q "$tool"; then
    pass "$tool appears in tool descriptions"
  else
    fail "$tool missing from tool descriptions"
  fi
done

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Cognitive tools: $PASSES passed, $FAILURES failed"
echo "========================================="

[ "$FAILURES" -eq 0 ] || exit 1
exit 0
