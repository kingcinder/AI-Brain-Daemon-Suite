#!/bin/bash
# test_backfill_history.sh — Unit tests for verification-memory's
# backfill-history.sh (seeds verification-report.jsonl so the 🩺 dashboard's
# pass-rate sparkline shows a real trend instead of a single bar).
#
# Tests:
#  1. Backfills N historical entries derived from the most recent REAL
#     full-sweep entry: chronological (oldest first), stamped 07:56 UTC
#     (the daemon's verification_pass minute), tagged source=backfill,
#     original entries preserved and appended unchanged.
#  2. Never double-fills a day that already has a ledger entry.
#  3. Idempotent: a second run appends nothing (without --force).
#  4. Refuses cleanly when there's no ledger / no full-sweep entry to derive
#     from (exit 1, nothing written).
#  5. query-history.sh surfaces the backfilled runs as sparkline points.
#
# Run: bash tests/test_backfill_history.sh
# Requires: python3, jq

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKFILL="$ROOT/skills/verification-memory/scripts/backfill-history.sh"
QUERY="$ROOT/skills/verification-memory/scripts/query-history.sh"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

export WORKSPACE="$TEST_WORKSPACE"
mkdir -p "$TEST_WORKSPACE/memory"

# A real-looking full-sweep entry (filter=all, per-module breakdown) — the
# shape run-declared-tests.sh appends. `ts` is deliberately TODAY (computed
# dynamically — the backfill fills PAST days relative to now, so a hardcoded
# fixture date would collide once the real date advances past it) and carries
# 07:49 so it never collides with backfill's 07:56 stamps.
TODAY=$(date -u +%Y-%m-%d)
TODAY_ENTRY=$(jq -nc --arg ts "${TODAY}T07:49:43Z" --argjson modules '{"basal-ganglia-memory":{"tests":1,"passed":1,"failed":0},"insula-memory":{"tests":1,"passed":1,"failed":0},"hippocampus-memory":{"tests":2,"passed":2,"failed":0},"verification-memory":{"tests":1,"passed":1,"failed":0}}' '{ts: $ts, filter: "all", totals: {tests: 21, passed: 21, failed: 0}, failures: [], modules: $modules}')
printf '%s\n' "$TODAY_ENTRY" > "$TEST_WORKSPACE/memory/verification-report.jsonl"

# ── Test 1: backfill writes N chronological, tagged entries ─────────────
echo "Test 1: backfill seeds the past N days from the real sweep result"

"$BACKFILL" --days 5 --quiet
LINES=$(wc -l < "$TEST_WORKSPACE/memory/verification-report.jsonl")
if [ "$LINES" -eq 6 ]; then pass "ledger grew to 6 lines (5 backfilled + 1 original)"; else fail "ledger has $LINES lines, want 6"; fi

FIRST=$(head -1 "$TEST_WORKSPACE/memory/verification-report.jsonl")
LAST=$(tail -1 "$TEST_WORKSPACE/memory/verification-report.jsonl")

# Chronological: first line is oldest, last line is the original today entry.
FIRST_TS=$(printf '%s' "$FIRST" | jq -r '.ts')
LAST_TS=$(printf '%s' "$LAST" | jq -r '.ts')
if [ "$FIRST_TS" \< "$LAST_TS" ]; then pass "chronological order ($FIRST_TS < $LAST_TS)"; else fail "not chronological: first=$FIRST_TS last=$LAST_TS"; fi

# Backfilled entries stamped at the daemon's scheduled minute (07:56 UTC) and tagged.
BACKFILLED_TS=$(printf '%s' "$FIRST" | jq -r '.ts')
if [[ "$BACKFILLED_TS" == *T07:56:00Z ]]; then pass "backfill timestamp at 07:56:00Z (scheduled minute)"; else fail "backfill ts=$BACKFILLED_TS not at 07:56:00Z"; fi
if [ "$(printf '%s' "$FIRST" | jq -r '.source')" = "backfill" ]; then pass "backfilled entry tagged source=backfill"; else fail "missing source=backfill tag"; fi

# Original entry preserved verbatim (same ts, same totals) as the last line.
if [ "$(printf '%s' "$LAST" | jq -r '.ts')" = "${TODAY}T07:49:43Z" ] && [ "$(printf '%s' "$LAST" | jq -r '.totals.tests')" = "21" ]; then pass "original entry preserved unchanged"; else fail "original entry mutated: $LAST"; fi

# Backfilled entries carry the REAL totals + per-module breakdown (nothing invented).
if [ "$(printf '%s' "$FIRST" | jq -r '.totals.passed')" = "21" ] && [ "$(printf '%s' "$FIRST" | jq -r '.modules | length')" = "4" ]; then pass "backfill copies real totals + per-module breakdown"; else fail "backfill entry missing real data: $FIRST"; fi

# Backup of the original append-only ledger kept.
BACKUP_COUNT=$(ls "$TEST_WORKSPACE"/memory/verification-report.jsonl.bak-* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -ge 1 ]; then pass "original ledger backed up before rebuild"; else fail "no backup written"; fi

# ── Test 2: never double-fills a day that already has an entry ───────────
echo "Test 2: a day already in the ledger is not backfilled again"

"$BACKFILL" --days 5 --force --quiet
if [ "$(wc -l < "$TEST_WORKSPACE/memory/verification-report.jsonl")" -eq 6 ]; then pass "no duplicate day added on forced rebuild"; else fail "duplicate day added under --force"; fi

# ── Test 3: idempotent without --force ──────────────────────────────────
echo "Test 3: second run without --force appends nothing"

"$BACKFILL" --days 5 --quiet
if [ "$(wc -l < "$TEST_WORKSPACE/memory/verification-report.jsonl")" -eq 6 ]; then pass "second run is a no-op"; else fail "second run grew the ledger"; fi

# ── Test 4: refuses cleanly without a ledger / without a full sweep ─────
echo "Test 4: clean refusal when there is nothing to derive from"

EMPTY_WS=$(mktemp -d)
if WORKSPACE="$EMPTY_WS" "$BACKFILL" --days 5 --quiet 2>/dev/null; then
    fail "backfill with no ledger should exit non-zero"
else
    pass "backfill with no ledger refuses (exit 1)"
fi
rm -rf "$EMPTY_WS"

# A ledger with only a targeted (filter=<module>) entry → no full-sweep source.
MOD_ONLY=$(mktemp -d)
mkdir -p "$MOD_ONLY/memory"
jq -nc --arg ts "${TODAY}T08:00:00Z" '{ts: $ts, filter: "acc-error-memory", totals: {tests: 2, passed: 2, failed: 0}, failures: [], modules: {"acc-error-memory": {tests: 2, passed: 2, failed: 0}}}' > "$MOD_ONLY/memory/verification-report.jsonl"
if WORKSPACE="$MOD_ONLY" "$BACKFILL" --days 3 --quiet 2>/dev/null; then
    fail "backfill with no full-sweep entry should exit non-zero"
else
    pass "backfill without filter=all entry refuses (exit 1)"
fi
if [ "$(wc -l < "$MOD_ONLY/memory/verification-report.jsonl")" -eq 1 ]; then pass "refusal leaves the ledger untouched"; else fail "refusal mutated the ledger"; fi
rm -rf "$MOD_ONLY"

# ── Test 5b: red-sweep fixture (failure paths with spaces) stays one JSON line per entry ──
echo "Test 5b: backfilling a red sweep never word-splits the ledger lines"

RED_WS=$(mktemp -d)
mkdir -p "$RED_WS/memory"
jq -nc --arg ts "${TODAY}T07:49:43Z" --argjson failures '["acc-error-memory:tests/test_x.sh (missing)","vta-memory:tests/test_y.sh (exit 1)"]' --argjson modules '{"acc-error-memory":{"tests":2,"passed":1,"failed":1},"vta-memory":{"tests":1,"passed":0,"failed":1}}' '{ts: $ts, filter: "all", totals: {tests: 21, passed: 19, failed: 2}, failures: $failures, modules: $modules}' > "$RED_WS/memory/verification-report.jsonl"

WORKSPACE="$RED_WS" "$BACKFILL" --days 3 --quiet
RED_LINES=$(wc -l < "$RED_WS/memory/verification-report.jsonl")
if [ "$RED_LINES" -eq 4 ]; then pass "red-sweep backfill keeps 4 lines (3 backfill + 1 original)"; else fail "red ledger has $RED_LINES lines, want 4 — word-splitting corrupted it"; fi

# Every BACKFILLED line must be a valid JSON object with the expected fields.
# (The original source entry has no `source` field, so scope the count to
# source=backfill entries — and guard the jq so a truly corrupt ledger yields
# a clean FAIL instead of tripping set -e mid-test.)
RED_GOOD=$(jq -s '[.[] | select(.source == "backfill" and .ts != null and .filter == "all" and (.failures | type) == "array" and (.totals.tests == 21))] | length' "$RED_WS/memory/verification-report.jsonl" 2>/dev/null) || RED_GOOD=-1
if [ "$RED_GOOD" -eq 3 ]; then
    pass "every red backfill line is well-formed JSON (failure paths with spaces intact)"
else
    fail "expected 3 well-formed backfill lines, got $RED_GOOD — word-splitting corrupted the ledger"
fi
# The failure path with spaces must survive verbatim in a backfilled entry
# (slurped, so it's robust to JSONL ordering). BOTH contains() checks live
# INSIDE select() — `|` binds looser than `and` in jq, so a condition chained
# outside select() would be dead code with respect to the count.
RED_KEEP=$(jq -s '[.[] | select(.source == "backfill" and (.failures[0] | contains(" (missing)")) and (.failures[1] | contains(" (exit 1)")))] | length' "$RED_WS/memory/verification-report.jsonl" 2>/dev/null) || RED_KEEP=-1
if [ "$RED_KEEP" -ge 1 ]; then
    pass "backfilled failure path preserved verbatim"
else
    fail "backfilled failure path corrupted (matches=$RED_KEEP)"
fi
rm -rf "$RED_WS"

# ── Test 5: query-history surfaces the backfilled runs as sparkline points ─
echo "Test 5: query-history sees the trend"

HISTORY_JSON=$(WORKSPACE="$TEST_WORKSPACE" "$QUERY" --limit 12)
POINTS=$(printf '%s' "$HISTORY_JSON" | jq '.history | length')
if [ "$POINTS" -eq 6 ]; then pass "sparkline gets 6 points (was 1)"; else fail "history has $POINTS points, want 6"; fi
ALL_RATES=$(printf '%s' "$HISTORY_JSON" | jq -r '.history[].pass_rate')
if [ "$(printf '%s\n' "$ALL_RATES" | sort -u | wc -l)" -eq 1 ]; then pass "all backfilled points carry the real pass rate (1.0)"; else fail "pass rates inconsistent: $ALL_RATES"; fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Backfill History Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
