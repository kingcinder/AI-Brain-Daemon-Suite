#!/bin/bash
# test_provenance_events.sh — Unit tests for `log-provenance.sh events`,
# the compact audit-table CLI over events.jsonl (the mirror of `show`, which
# reads the patch DAG). The steward audits every autonomy-mode decision from
# the terminal: `log-provenance.sh events --filter autonomy`.
#
# Tests:
#  1. `events` renders a table with a header and all seeded rows.
#  2. `--filter autonomy` narrows to autonomy.* events only.
#  3. `--limit` caps the newest rows.
#  4. Detail summaries render (mode · transition / autonomy_mode +
#     review_mode · reason) instead of raw JSON.
#  5. A missing events.jsonl degrades gracefully (message + exit 0).
#
# Run: bash tests/test_provenance_events.sh
# Requires: bash, jq (the suite's standard set)

set -euo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

PROV() { WORKSPACE="$WS" bash "$ROOT/core/provenance/log-provenance.sh" "$@"; }

# ── Seed events.jsonl (two autonomy decisions + one unrelated) ────────────
PROV event --event autonomy.mode.decided --actor deep-brain-kernel \
  --detail '{"mode":"auto_mode","auto":true,"transition":"granted","computed_at":"2026-08-08T09:00:00Z"}' >/dev/null
PROV event --event autonomy.gate.deferred --actor run-pipeline \
  --detail '{"autonomy_mode":"steward_mode","review_mode":"full_review","reason":"steward_full_review_deferred"}' >/dev/null
PROV event --event executive.goal_proposed --actor executive \
  --detail '{"goal_id":"g1","priority":0.8}' >/dev/null

# ── Test 1: full table + header ───────────────────────────────────────────
echo "Test 1: events renders a header and all rows"
ALL=$(PROV events)
if echo "$ALL" | grep -q '^TS ' && echo "$ALL" | grep -q 'EVENT' && echo "$ALL" | grep -q 'ACTOR'; then
  pass "table header present"
else
  fail "table header missing: $ALL"
fi
if echo "$ALL" | grep -q 'autonomy.mode.decided' \
  && echo "$ALL" | grep -q 'autonomy.gate.deferred' \
  && echo "$ALL" | grep -q 'executive.goal_proposed'; then
  pass "all 3 seeded events rendered"
else
  fail "rows missing: $ALL"
fi

# ── Test 2: --filter autonomy ─────────────────────────────────────────────
echo "Test 2: --filter autonomy narrows to autonomy events"
AUTO=$(PROV events --filter autonomy)
if echo "$AUTO" | grep -q 'autonomy.mode.decided' && echo "$AUTO" | grep -q 'autonomy.gate.deferred'; then
  pass "both autonomy events shown"
else
  fail "autonomy events missing: $AUTO"
fi
if echo "$AUTO" | grep -q 'executive.goal_proposed'; then
  fail "non-autonomy event leaked through --filter autonomy"
else
  pass "non-autonomy event filtered out"
fi

# ── Test 3: --limit caps newest rows ──────────────────────────────────────
echo "Test 3: --limit 1 shows only the newest event"
LIM=$(PROV events --filter autonomy --limit 1)
if echo "$LIM" | grep -q 'autonomy.gate.deferred' && ! echo "$LIM" | grep -q 'autonomy.mode.decided'; then
  pass "--limit 1 keeps the newest autonomy event"
else
  fail "--limit 1 wrong: $LIM"
fi

# ── Test 4: detail summaries render ───────────────────────────────────────
echo "Test 4: detail column summarizes instead of raw JSON"
if echo "$ALL" | grep -q 'auto_mode · granted'; then
  pass "mode.decided detail renders 'mode · transition'"
else
  fail "mode.decided summary missing: $ALL"
fi
if echo "$ALL" | grep -q 'steward_mode + full_review · steward_full_review_deferred'; then
  pass "gate.deferred detail renders 'autonomy_mode + review_mode · reason'"
else
  fail "gate.deferred summary missing: $ALL"
fi

# ── Test 5: missing file degrades gracefully ──────────────────────────────
echo "Test 5: no events file → graceful message + exit 0"
WS2=$(mktemp -d)
OUT=$(WORKSPACE="$WS2" bash "$ROOT/core/provenance/log-provenance.sh" events 2>&1) || true
if echo "$OUT" | grep -q 'No events logged yet'; then
  pass "graceful message on missing events.jsonl"
else
  fail "missing-file output: $OUT"
fi
rm -rf "$WS2"

echo ""
echo "─────────────────────────────────────────"
echo "Provenance Events CLI Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
