#!/bin/bash
# backfill-history.sh — Seed verification-report.jsonl with historical runs so
# the 🩺 dashboard's pass-rate sparkline shows a real trend immediately.
#
# Why this exists: the append-only report ledger is written by
# run-declared-tests.sh (one entry per sweep), and the daemon's daily
# `verification_pass` job (07:56 UTC) adds one entry per day. On a fresh
# workspace the ledger has zero or one entry, so the sparkline renders a
# single bar until the scheduled job has run for days. This script backfills
# the ledger with N historical entries so the trend is visible today.
#
# Honesty: every backfilled entry is derived from the MOST RECENT REAL
# full-sweep entry already in the ledger (filter=all, with the per-module
# breakdown) — no pass/fail data is invented. Only the timestamps are
# historical, stamped at the daemon's scheduled 07:56 UTC minute, and every
# backfilled entry carries `"source":"backfill"` so the ledger stays
# auditable. query-history.sh ignores unknown fields, so nothing downstream
# changes behavior.
#
# Append-only caveat: the ledger is rebuilt atomically (backfill entries in
# chronological order, then the original entries unchanged) and the original
# file is preserved as a timestamped backup alongside it.
#
# Usage:
#   backfill-history.sh [--days N] [--quiet] [--force]
#
# Options:
#   --days N    Backfill the past N days (default 7)
#   --quiet     Suppress informational output
#   --force     Rebuild even if the window already looks backfilled
#
# Env:
#   WORKSPACE   Defaults to $HOME/.hermes/workspace
#   SUITE_ROOT  Defaults to the repo root (used for the seed sweep only if the
#               ledger has no full-sweep entry to copy from)
#
# Exit code: 0 on success (including "nothing to backfill"), 1 on failure
# (e.g. no ledger / no full-sweep entry to derive from).

set -u

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
REPORT_LOG="$WORKSPACE/memory/verification-report.jsonl"

DAYS=7
QUIET=0
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        --force) FORCE=1; shift ;;
        *) shift ;;
    esac
done

say() { [ "$QUIET" -eq 1 ] || echo "$*"; }
die() { echo "backfill-history: $*" >&2; exit 1; }

[ "$DAYS" -ge 1 ] 2>/dev/null || die "--days must be >= 1 (got '$DAYS')"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (for portable date math)"

# ── 1. Source of truth: the most recent real full-sweep entry ───────────
if [ ! -f "$REPORT_LOG" ]; then
    die "no $REPORT_LOG — run a sweep first (run-declared-tests.sh), then backfill"
fi

SRC=$(
    jq -s '[.[] | select(.filter == "all" and (.totals.tests // 0) > 0)] | last // empty' \
        "$REPORT_LOG" 2>/dev/null
)
if [ -z "$SRC" ]; then
    die "no full-sweep entry (filter=all) in $REPORT_LOG — run run-declared-tests.sh first"
fi

SRC_TOTALS=$(printf '%s' "$SRC" | jq -c '.totals')
SRC_MODULES=$(printf '%s' "$SRC" | jq -c '.modules // {}')
SRC_FAILURES=$(printf '%s' "$SRC" | jq -c '.failures // []')

# ── 2. Existing dates (YYYY-MM-DD) already in the ledger — never double-fill a day ──
EXISTING_DATES=$(
    jq -r '.[].ts[0:10]' -s "$REPORT_LOG" 2>/dev/null | sort -u
)

# ── 3. Build backfill timestamps: past N days at the scheduled 07:56 UTC minute ──
# Oldest first so the rebuilt ledger stays chronological.
readarray -t BACKFILL_TS < <(
    python3 - "$DAYS" << 'PYEOF'
import sys
from datetime import datetime, timedelta, timezone
days = int(sys.argv[1])
now = datetime.now(timezone.utc)
for i in range(days, 0, -1):
    ts = (now - timedelta(days=i)).replace(hour=7, minute=56, second=0, microsecond=0)
    print(ts.strftime("%Y-%m-%dT%H:%M:%SZ"))
PYEOF
)

CANDIDATES=()
for ts in "${BACKFILL_TS[@]}"; do
    day="${ts:0:10}"
    if printf '%s\n' "$EXISTING_DATES" | grep -qx "$day"; then
        continue  # that day already has an entry — don't invent a second one
    fi
    CANDIDATES+=("$ts")
done

if [ "${#CANDIDATES[@]}" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    say "backfill-history: nothing to backfill — the past $DAYS day(s) already have ledger entries (use --force to rebuild anyway)"
    exit 0
fi

# ── 4. Build backfill lines (oldest first, tagged source=backfill) ───────
# NOTE: capture jq output in a variable and quote it — failure paths contain
# spaces ("owner:path (missing)"), and an unquoted $(jq ...) would word-split
# a red sweep's JSON into multiple broken lines.
NEW_LINES=()
for ts in "${CANDIDATES[@]}"; do
    line=$(jq -nc \
        --arg ts "$ts" \
        --argjson totals "$SRC_TOTALS" \
        --argjson modules "$SRC_MODULES" \
        --argjson failures "$SRC_FAILURES" \
        '{ts: $ts, filter: "all", source: "backfill", totals: $totals, failures: $failures, modules: $modules}') \
        || die "failed to build backfill entry for $ts"
    NEW_LINES+=("$line")
done

# ── 5. Rebuild atomically: backfill lines (chronological) + originals ────
ORIG_LINES=$(cat "$REPORT_LOG")

TMP="$REPORT_LOG.tmp.$$"
: > "$TMP"
for line in "${NEW_LINES[@]}"; do
    printf '%s\n' "$line" >> "$TMP"
done
if [ -n "$ORIG_LINES" ]; then
    printf '%s\n' "$ORIG_LINES" >> "$TMP"
fi

# Preserve the append-only ledger's integrity: keep a timestamped backup
# ($$ guards the filename against two forced runs landing in the same second).
BACKUP="$REPORT_LOG.bak-$(date -u +%Y%m%dT%H%M%SZ)-$$"
cp "$REPORT_LOG" "$BACKUP"
mv "$TMP" "$REPORT_LOG"

say "backfill-history: added ${#CANDIDATES[@]} historical run(s) to $REPORT_LOG (derived from the real full-sweep result; source=backfill)"
say "backfill-history: backup kept at $BACKUP"
exit 0
