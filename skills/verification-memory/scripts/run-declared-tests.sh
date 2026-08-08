#!/bin/bash
# run-declared-tests.sh — Verification region: run every test each module
# declared in its capability-manifest.json (the suite's proprioception).
#
# Discovery is manifest-driven: this script walks skills/*/capability-manifest.json
# + core/executive/capability-manifest.json (the same set validate-manifest.sh
# --all checks), parses each `tests` entry {path, kind}, and runs every declared
# test against the suite root. No per-region wiring — add a test to any module's
# manifest and it becomes part of the next verification pass automatically.
#
# Usage:
#   run-declared-tests.sh [--module <name>] [--list] [--quiet] [--timeout N]
#
# Options:
#   --module <name>   Run only one module's declared tests
#   --list            Print what the manifests declare, run nothing
#   --quiet           Suppress per-test output (summary only)
#   --timeout N       Per-test timeout in seconds (default 300)
#
# Env:
#   WORKSPACE   Defaults to $HOME/.hermes/workspace
#   SUITE_ROOT  Defaults to the repo root (three dirs up from this script)
#
# Exit code: 0 if every declared test passed, 1 otherwise (CI/daemon gate).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SUITE_ROOT="${SUITE_ROOT:-$(cd "$SKILL_DIR/../.." && pwd)}"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/verification-state.json"
REPORT_LOG="$WORKSPACE/memory/verification-report.jsonl"
PUBLISH_SH="$SUITE_ROOT/core/signaling/publish.sh"

MODULE_FILTER=""
LIST_ONLY=0
QUIET=0
TIMEOUT_SEC=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) MODULE_FILTER="$2"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$WORKSPACE/memory"

# ── 1. Discover manifests ────────────────────────────────────────────────
MANIFESTS=()
for f in "$SUITE_ROOT"/skills/*/capability-manifest.json; do
    [ -f "$f" ] && MANIFESTS+=("$f")
done
[ -f "$SUITE_ROOT/core/executive/capability-manifest.json" ] && MANIFESTS+=("$SUITE_ROOT/core/executive/capability-manifest.json")

if [ "$LIST_ONLY" -eq 1 ]; then
    echo "Declared tests (manifest-driven discovery):"
    echo "--------------------------------------------"
    declare -A LISTED
    for f in "${MANIFESTS[@]}"; do
        mod=$(jq -r '.module // "unknown"' "$f" 2>/dev/null)
        while IFS=$'\t' read -r path kind; do
            [ -z "$path" ] && continue
            # Dedupe: executive-function has two manifests declaring the same
            # phase2/5/6 harnesses — list each path once.
            if [ -z "${LISTED[$path]+_}" ]; then
                LISTED["$path"]=1
                printf '%s\t%s\t%s\n' "$mod" "$path" "${kind:-unit}"
            fi
        done < <(jq -r '.tests[]? | [.path, (.kind // "unit")] | @tsv' "$f" 2>/dev/null)
    done
    exit 0
fi

# ── 2. Build the test plan (dedupe by path) ──────────────────────────────
declare -A PLAN     # path -> "kind"
declare -A OWNER    # path -> module that declared it (first)
declare -a ORDER
for f in "${MANIFESTS[@]}"; do
    mod=$(jq -r '.module // "unknown"' "$f" 2>/dev/null)
    if [ -n "$MODULE_FILTER" ] && [ "$mod" != "$MODULE_FILTER" ]; then
        continue
    fi
    while IFS=$'\t' read -r path kind; do
        [ -z "$path" ] && continue
        # Dedupe by path in BOTH modes: executive-function has two manifests
        # (skills/executive-function AND core/executive) that declare the same
        # phase2/5/6 harnesses — without this, a targeted run would execute
        # them twice. Targeted mode only processes the filtered module's
        # manifests anyway, so dedupe loses nothing.
        if [ -z "${PLAN[$path]+_}" ]; then
            ORDER+=("$path")
            PLAN["$path"]="${kind:-unit}"
            OWNER["$path"]="$mod"
        fi
    done < <(jq -r '.tests[]? | [.path, (.kind // "unit")] | @tsv' "$f" 2>/dev/null)
done

if [ "${#ORDER[@]}" -eq 0 ]; then
    echo "verification: no declared tests found (module filter: '${MODULE_FILTER:-all}')"
    exit 0
fi

# ── 3. Run the plan ──────────────────────────────────────────────────────
TOTAL=0; PASSED=0; FAILED=0
FAILED_PATHS=()
declare -A MOD_TESTS MOD_PASSED MOD_FAILED   # per-module breakdown for the ledger
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# timeout(1) is GNU coreutils; not guaranteed on macOS (listed in requires.os).
# Fall back to a plain run when it's absent — applied in BOTH quiet and
# verbose modes so the region never fails with rc=127 on systems without it.
if command -v timeout >/dev/null 2>&1; then
    run_one() {
        if [ "$QUIET" -eq 1 ]; then
            timeout "$TIMEOUT_SEC" bash "$1" >/dev/null 2>&1
        else
            timeout "$TIMEOUT_SEC" bash "$1"
        fi
    }
else
    run_one() {
        if [ "$QUIET" -eq 1 ]; then
            bash "$1" >/dev/null 2>&1
        else
            bash "$1"
        fi
    }
fi

for path in "${ORDER[@]}"; do
    kind="${PLAN[$path]}"
    owner="${OWNER[$path]}"
    test_file="$SUITE_ROOT/$path"
    TOTAL=$((TOTAL + 1))

    if [ ! -f "$test_file" ]; then
        FAILED=$((FAILED + 1))
        MOD_TESTS["$owner"]=$(( ${MOD_TESTS["$owner"]:-0} + 1 ))
        MOD_FAILED["$owner"]=$(( ${MOD_FAILED["$owner"]:-0} + 1 ))
        FAILED_PATHS+=("$owner:$path (missing)")
        echo "FAIL  $owner  $path  (declared test file missing at $test_file)" >&2
        continue
    fi

    start=$(date +%s)
    run_one "$test_file"
    rc=$?
    end=$(date +%s)
    dur=$((end - start))

    if [ "$rc" -eq 0 ]; then
        PASSED=$((PASSED + 1))
        MOD_TESTS["$owner"]=$(( ${MOD_TESTS["$owner"]:-0} + 1 ))
        MOD_PASSED["$owner"]=$(( ${MOD_PASSED["$owner"]:-0} + 1 ))
        [ "$QUIET" -eq 0 ] && echo "PASS  $owner  $path  (${dur}s)"
    else
        FAILED=$((FAILED + 1))
        MOD_TESTS["$owner"]=$(( ${MOD_TESTS["$owner"]:-0} + 1 ))
        MOD_FAILED["$owner"]=$(( ${MOD_FAILED["$owner"]:-0} + 1 ))
        FAILED_PATHS+=("$owner:$path (exit $rc)")
        echo "FAIL  $owner  $path  (exit $rc, ${dur}s)" >&2
    fi
done

# ── 4. Record state + report ledger ──────────────────────────────────────
echo "verification: $TOTAL declared test(s) — $PASSED passed, $FAILED failed"

# Payload keys use gate.sh's resolvable placeholder names (type/pattern/
# mitigation/description) so routes can surface WHICH module broke. Values are
# kept single-token (gate.sh word-splits arg templates), so pattern is the
# owner:path portion of the first failure — no spaces.
if [ -x "$PUBLISH_SH" ]; then
    if [ "$FAILED" -eq 0 ]; then
        "$PUBLISH_SH" --type verification --source verification-memory \
            --signal tests_passed --intensity 0.6 \
            --payload "{\"type\":\"tests_passed\",\"pattern\":\"all_declared_tests_green\",\"description\":\"${TOTAL}_tests_passed\"}" >/dev/null 2>&1 || true
    else
        first="${FAILED_PATHS[0]}"
        first_safe=$(printf '%s' "$first" | cut -d' ' -f1)  # drop trailing "(exit N)"
        "$PUBLISH_SH" --type verification --source verification-memory \
            --signal test_failure --intensity 0.8 \
            --payload "{\"type\":\"test_failure\",\"pattern\":\"$first_safe\",\"description\":\"${FAILED}_declared_tests_failed\"}" >/dev/null 2>&1 || true
    fi
fi

# State file (atomic write via tmp) — always JSON-valid via jq
if [ "${#FAILED_PATHS[@]}" -gt 0 ]; then
    FAILURES_JSON=$(printf '%s\n' "${FAILED_PATHS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
else
    FAILURES_JSON="null"
fi
jq -n \
    --arg lastRun "$NOW" \
    --arg moduleFilter "${MODULE_FILTER:-all}" \
    --argjson tests "$TOTAL" --argjson passed "$PASSED" --argjson failed "$FAILED" \
    --argjson failures "$FAILURES_JSON" \
    '{schema: 1, lastRun: $lastRun, moduleFilter: $moduleFilter, totals: {tests: $tests, passed: $passed, failed: $failed, skipped: 0}, lastFailure: $failures}' \
    > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

# Per-module breakdown (owner -> {tests, passed, failed}) so history queries
# can compute per-region pass-rate trends from the append-only ledger.
MODULES_JSON="{}"
if [ "${#MOD_TESTS[@]}" -gt 0 ]; then
    MODULES_JSON=$(
        for m in "${!MOD_TESTS[@]}"; do
            jq -nc --arg m "$m" \
                --argjson t "${MOD_TESTS["$m"]:-0}" \
                --argjson p "${MOD_PASSED["$m"]:-0}" \
                --argjson f "${MOD_FAILED["$m"]:-0}" \
                '{key: $m, value: {tests: $t, passed: $p, failed: $f}}'
        done | jq -s 'from_entries'
    )
fi

# Append-only report ledger (one compact JSON record per line — true JSONL)
jq -nc --arg ts "$NOW" --arg filter "${MODULE_FILTER:-all}" \
    --argjson tests "$TOTAL" --argjson passed "$PASSED" --argjson failed "$FAILED" \
    --argjson failures "$(printf '%s\n' "${FAILED_PATHS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson modules "$MODULES_JSON" \
    '{ts: $ts, filter: $filter, totals: {tests: $tests, passed: $passed, failed: $failed}, failures: $failures, modules: $modules}' \
    >> "$REPORT_LOG" 2>/dev/null || true

# ── 5. Regenerate human-readable state + dashboard fragment ─────────────
[ -x "$SCRIPT_DIR/sync-state.sh" ] && "$SCRIPT_DIR/sync-state.sh" >/dev/null 2>&1 || true

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
