#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0; PASS=0
UT_OUT="$(mktemp)"
UT_ERR="$(mktemp)"
trap 'rm -f "$UT_OUT" "$UT_ERR"' EXIT
for t in "$ROOT"/tests/test_*.sh; do
  name=$(basename "$t")
  if bash "$t" >"$UT_OUT" 2>"$UT_ERR"; then
    echo "PASS $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; cat "$UT_ERR"; FAIL=$((FAIL+1))
  fi
done
echo "Skill unit tests: $PASS passed, $FAIL failed"
exit $FAIL
