#!/bin/bash
# pfc_decide_harness.sh — closed-loop verification for prefrontal-cortex-memory's
# decide.sh: proves the arbitration score actually moves in response to each
# sibling signal it claims to read, using synthetic sibling state files
# (no real siblings, no local LLM required — PFC_SEMANTIC_MATCHING=off forces
# the deterministic heuristic path). Exits non-zero if any assertion fails.
#
# Usage: WORKSPACE is created fresh under a temp dir; nothing outside it is
# touched. Run from anywhere:
#   bash tests/pfc_decide_harness.sh [path-to-prefrontal-cortex-memory-skill-dir]

set -u
SKILL_DIR="${1:-$(cd "$(dirname "$0")/../skills/prefrontal-cortex-memory" && pwd)}"
DECIDE="$SKILL_DIR/scripts/decide.sh"

if [ ! -x "$DECIDE" ]; then
  echo "FATAL: $DECIDE not found or not executable"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required (decide.sh depends on it)"
  exit 2
fi

WS=$(mktemp -d)
mkdir -p "$WS/memory"
trap 'rm -rf "$WS"' EXIT

cat > "$WS/memory/pfc-state.json" << 'EOF'
{"version":"1.0","lastUpdated":"","executiveLoad":0.3,
 "goals":[{"description":"Ship the v2 dashboard","priority":0.8,"status":"active"}],
 "inhibitions":[{"pattern":"interrupt mid-task","reason":"breaks flow","strength":0.9}],
 "decisionLog":[]}
EOF

FAILURES=0
run() {
  WORKSPACE="$WS" PFC_SEMANTIC_MATCHING=off "$DECIDE" "$@"
}
score_of() {
  # score_of <json> <option_id>
  echo "$1" | jq -r --arg id "$2" '.scores[$id] // "null"'
}
assert_gt() {
  # assert_gt <label> <a> <b>  — a strictly greater than b
  local label="$1" a="$2" b="$3"
  if python3 -c "import sys; sys.exit(0 if float('$a') > float('$b') else 1)"; then
    echo "  PASS: $label ($a > $b)"
  else
    echo "  FAIL: $label ($a should be > $b)"
    FAILURES=$((FAILURES + 1))
  fi
}
assert_lt() {
  local label="$1" a="$2" b="$3"
  if python3 -c "import sys; sys.exit(0 if float('$a') < float('$b') else 1)"; then
    echo "  PASS: $label ($a < $b)"
  else
    echo "  FAIL: $label ($a should be < $b)"
    FAILURES=$((FAILURES + 1))
  fi
}

OPTIONS='[{"id":"project_work","label":"Work on project","weight":1.0},{"id":"idle","label":"Stay quiet","weight":0.3},{"id":"dreaming","label":"Consolidate memories","weight":0.3},{"id":"social_interaction","label":"Reach out to check in","weight":0.3}]'

echo "--- baseline (no sibling state) ---"
BASELINE=$(run --context test --options "$OPTIONS")
BASE_PROJECT=$(score_of "$BASELINE" project_work)
BASE_IDLE=$(score_of "$BASELINE" idle)
BASE_DREAM=$(score_of "$BASELINE" dreaming)
BASE_SOCIAL=$(score_of "$BASELINE" social_interaction)
echo "$BASELINE" | jq -c '.scores'

echo "--- A: high cognitive load + context saturation -> should suppress project_work, boost idle ---"
echo '{"channels":{"cognitiveLoad":0.8,"contextSaturation":0.75,"gutSignal":0.0}}' > "$WS/memory/interoceptive-state.json"
A=$(run --context test --options "$OPTIONS")
echo "$A" | jq -c '.scores'
assert_lt "high load suppresses project_work" "$(score_of "$A" project_work)" "$BASE_PROJECT"
assert_gt "high load boosts idle"             "$(score_of "$A" idle)"         "$BASE_IDLE"
rm -f "$WS/memory/interoceptive-state.json"

echo "--- B: unresolved conflicts + error patterns -> should boost dreaming ---"
echo '{"conflictLoad":0.7}' > "$WS/memory/conflict-state.json"
echo '{"activePatterns":[{"x":1},{"x":2},{"x":3}]}' > "$WS/memory/acc-state.json"
B=$(run --context test --options "$OPTIONS")
echo "$B" | jq -c '.scores'
assert_gt "conflicts/errors boost dreaming" "$(score_of "$B" dreaming)" "$BASE_DREAM"
rm -f "$WS/memory/conflict-state.json" "$WS/memory/acc-state.json"

echo "--- C: low energy + negative mood -> should suppress project_work, boost idle ---"
echo '{"dimensions":{"valence":-0.5,"energy":0.2}}' > "$WS/memory/emotional-state.json"
C=$(run --context test --options "$OPTIONS")
echo "$C" | jq -c '.scores'
assert_lt "low mood/energy suppresses project_work" "$(score_of "$C" project_work)" "$BASE_PROJECT"
assert_gt "low mood/energy boosts idle"             "$(score_of "$C" idle)"         "$BASE_IDLE"
rm -f "$WS/memory/emotional-state.json"

echo "--- D: open social loops -> should boost social_interaction ---"
echo '{"relationships":[{"openLoops":["reply to Sam","follow up on X"]}]}' > "$WS/memory/social-state.json"
D=$(run --context test --options "$OPTIONS")
echo "$D" | jq -c '.scores'
assert_gt "open loops boost social_interaction" "$(score_of "$D" social_interaction)" "$BASE_SOCIAL"
rm -f "$WS/memory/social-state.json"

echo "--- E: active goal boosts the option that matches its description ---"
E=$(run --context test --options "$OPTIONS")
echo "$E" | jq -c '.scores'
assert_gt "active goal boosts project_work over baseline weight" "$(score_of "$E" project_work)" "0.5"

echo "--- F: inhibition suppresses the option it matches ---"
OPTIONS_F='[{"id":"interrupt_now","label":"interrupt mid-task to ask a question","weight":1.0},{"id":"idle","label":"Stay quiet","weight":0.3}]'
F=$(run --context test --options "$OPTIONS_F")
echo "$F" | jq -c '.scores'
assert_lt "inhibition suppresses interrupt_now below its own weight" "$(score_of "$F" interrupt_now)" "1.0"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "✅ All PFC arbitration assertions passed — decide.sh's score adjustments are real, not just documented."
  exit 0
else
  echo "❌ $FAILURES assertion(s) failed — decide.sh's behavior does not match what its own docs/comments claim."
  exit 1
fi
