#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0; PASS=0
for t in "$ROOT"/tests/test_*.sh; do
  name=$(basename "$t")
  if bash "$t" >/tmp/skill_ut_out 2>/tmp/skill_ut_err; then
    echo "PASS $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; cat /tmp/skill_ut_err; FAIL=$((FAIL+1))
  fi
done
echo "Skill unit tests: $PASS passed, $FAIL failed"
exit $FAIL
