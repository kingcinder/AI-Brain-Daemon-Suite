#!/bin/bash
# run-module-tests.sh — Verification region: run ONE module's declared tests.
#
# This is the signal-triggered entry point (route-signals.sh dispatches
# inbound routes here with --module {source}). A cooldown prevents signal
# storms from re-running the same module's suite repeatedly.
#
# Usage:
#   run-module-tests.sh --module <name> [--force] [--cooldown N]
#
# Options:
#   --module <name>  Module whose declared tests to run (required)
#   --force          Bypass the cooldown
#   --cooldown N     Min seconds between runs of the same module (default 900)
#
# Exit code: 0 on pass or cooldown-skip, 1 on test failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_ROOT="${SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
COOLDOWN_FILE="$WORKSPACE/memory/.verification-cooldowns"

MODULE=""
FORCE=0
COOLDOWN=900
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) MODULE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --cooldown) COOLDOWN="$2"; shift 2 ;;
        --quiet) EXTRA_ARGS+=("--quiet"); shift ;;
        --timeout) EXTRA_ARGS+=("--timeout" "$2"); shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$MODULE" ]; then
    echo "run-module-tests.sh: --module <name> is required" >&2
    exit 2
fi

# ── Cooldown: don't re-run the same module more than once per window ─────
mkdir -p "$WORKSPACE/memory"
if [ "$FORCE" -eq 0 ] && [ -f "$COOLDOWN_FILE" ]; then
    # Anchored match: cooldown lines are "<module> <epoch>"; use the exact
    # module token, not a substring (avoids cross-matching prefix modules).
    last=$(awk -v m="$MODULE" '$1 == m { print $2 }' "$COOLDOWN_FILE" 2>/dev/null | tail -1 || true)
    if [ -n "$last" ]; then
        now=$(date +%s)
        elapsed=$((now - last))
        if [ "$elapsed" -lt "$COOLDOWN" ]; then
            echo "verification: $MODULE tested ${elapsed}s ago (cooldown ${COOLDOWN}s) — skipping (use --force)"
            exit 0
        fi
    fi
fi

echo "verification: running declared tests for $MODULE"
"$SCRIPT_DIR/run-declared-tests.sh" --module "$MODULE" "${EXTRA_ARGS[@]}"
rc=$?

# Record run time for cooldown (even on failure — avoids hammering a red suite)
date +%s | sed "s/^/$MODULE /" >> "$COOLDOWN_FILE"
# Trim cooldown file to last 64 entries
tail -n 64 "$COOLDOWN_FILE" > "$COOLDOWN_FILE.tmp" 2>/dev/null && mv "$COOLDOWN_FILE.tmp" "$COOLDOWN_FILE"

exit "$rc"
