#!/bin/bash
# Unit: health-context.sh (ROADMAP M5) surfaces daemon failure streaks,
# verification failures, ACC lessons, graduation state, and proposal-store
# counts as ONE valid JSON block — the outcome-driven input to the self-mod
# LLM proposal generator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory/self-mod/proposals"

HC="$ROOT/core/self-mod/health-context.sh"
[ -x "$HC" ] || { echo "FAIL: health-context.sh not executable"; exit 1; }

# Empty workspace → valid JSON, zeroed fields, full_review default.
OUT=$(WORKSPACE="$WORKSPACE" bash "$HC")
echo "$OUT" | jq -e '.daemon_streaks == [] and .verification.failures == [] and .acc_lessons == [] and .graduation.review_mode == "full_review" and .proposal_store.queued == 0' >/dev/null \
  || { echo "FAIL: empty-workspace shape: $OUT"; exit 1; }
echo "$OUT" | jq -e '.acc_calibration.total_conflicts == 0 and .acc_calibration.hit_rate == 0.0 and .acc_calibration.by_type == {}' >/dev/null \
  || { echo "FAIL: acc_calibration key present + zeroed on empty workspace: $OUT"; exit 1; }

# Seed every source with realistic data.
cat > "$WORKSPACE/memory/deep-brain-kernel-state.json" << 'EOF'
{"jobStats": {"verification_pass": {"consecutive_failures": 3, "last_error": "boom", "last_failure_utc": "2026-08-08T07:56:00Z"}}}
EOF
cat > "$WORKSPACE/memory/verification-report.jsonl" << 'EOF'
{"ts":"2026-08-08T07:56:00Z","filter":"all","totals":{"tests":21,"passed":19,"failed":2},"failures":["acc-error-memory:tests/test_x.sh (exit 1)","vta-memory:tests/test_y.sh (missing)"]}
EOF
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{"resolved": {"bad-pattern": {"count": 3, "daysClear": 5, "lesson": {"mitigation": "check config first", "insight": "validate inputs"}}}}
EOF
cat > "$WORKSPACE/memory/self-mod/graduation-streak.json" << 'EOF'
{"clean_streak": 20, "clean_streak_target": 20}
EOF
echo '{"proposal_id":"p1","status":"queued","module":"x"}' > "$WORKSPACE/memory/self-mod/proposals/p1.json"
echo '{"proposal_id":"p2","status":"rejected","module":"x"}' > "$WORKSPACE/memory/self-mod/proposals/p2.json"
echo '{"proposal_id":"p3","status":"deployed","module":"x"}' > "$WORKSPACE/memory/self-mod/proposals/p3.json"

OUT2=$(WORKSPACE="$WORKSPACE" bash "$HC")
echo "$OUT2" | jq -e '.daemon_streaks[0].job == "verification_pass" and .daemon_streaks[0].consecutive_failures == 3 and .daemon_streaks[0].last_error == "boom"' >/dev/null \
  || { echo "FAIL: daemon streak surfacing: $OUT2"; exit 1; }
echo "$OUT2" | jq -e '.verification.failed == 2 and (.verification.failures[0] | contains("acc-error-memory"))' >/dev/null \
  || { echo "FAIL: verification failures: $OUT2"; exit 1; }
echo "$OUT2" | jq -e '.acc_lessons[0].pattern == "bad-pattern" and .acc_lessons[0].mitigation == "check config first"' >/dev/null \
  || { echo "FAIL: acc lessons: $OUT2"; exit 1; }
echo "$OUT2" | jq -e '.graduation.review_mode == "relaxed_review" and .graduation.clean_streak == 20' >/dev/null \
  || { echo "FAIL: graduation state: $OUT2"; exit 1; }
echo "$OUT2" | jq -e '.proposal_store.queued == 1 and .proposal_store.rejected == 1 and .proposal_store.deployed == 1' >/dev/null \
  || { echo "FAIL: proposal-store counts: $OUT2"; exit 1; }
# acc_calibration is fed through from acc-calibration.sh (the seeded
# acc-state.json has no firstSeen, so it must be zeroed but PRESENT).
echo "$OUT2" | jq -e '.acc_calibration.total_errors == 0 and (.acc_calibration.total_conflicts | type) == "number"' >/dev/null \
  || { echo "FAIL: acc_calibration feed-through: $OUT2"; exit 1; }

# Corrupt sources must degrade, not abort (invalid JSON in one file).
echo 'not-json{{' > "$WORKSPACE/memory/verification-report.jsonl"
OUT3=$(WORKSPACE="$WORKSPACE" bash "$HC")
echo "$OUT3" | jq -e '.verification.failures == []' >/dev/null \
  || { echo "FAIL: corrupt-source degradation: $OUT3"; exit 1; }
# acc_calibration survives a corrupt acc-state.json (degraded, never aborts).
echo 'not-json{{' > "$WORKSPACE/memory/acc-state.json"
OUT4=$(WORKSPACE="$WORKSPACE" bash "$HC")
echo "$OUT4" | jq -e '.acc_calibration.total_conflicts == 0 and .acc_calibration.hit_rate == 0.0' >/dev/null \
  || { echo "FAIL: acc_calibration survives corrupt acc-state: $OUT4"; exit 1; }

echo "PASS: health-context"
