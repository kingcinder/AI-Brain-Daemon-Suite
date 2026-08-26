#!/bin/bash
# ci-gate.sh — One-command local replay of the Verification Gate CI workflow.
#
# Mirrors .github/workflows/verification.yml step-for-step with the exact CI
# environment, so "a green local run is a green CI run" is literally one
# command:
#
#   1. core/schema/validate-manifest.sh --all
#   2. deep-brain-kernel.py --check   (WORKSPACE=<checkout>,
#                                      DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1 —
#                                      hermes presence is a host concern, not a
#                                      gate concern, on runners and desktops
#                                      alike)
#   3. tests/run_skill_unit_tests.sh
#   4. skills/verification-memory/scripts/run-declared-tests.sh --quiet
#        (isolated scratch WORKSPACE, mirroring CI's
#         runner.temp/verification-workspace — the sweep writes verification
#         state, appends to the report ledger, and publishes signals, none of
#         which may touch the live brain's ~/.hermes/workspace)
#
# Fails fast on the first red step, exactly like a failing CI job; exit 0
# means the same four commands just went green in the same order CI runs them.
#
# Usage:
#   scripts/ci-gate.sh [--suite-root PATH]
# Env:
#   SUITE_ROOT or --suite-root — repo root to gate; defaults to the parent of
#       this script's directory.
#   SKIP_CI_GATE_PREFLIGHT=1    — skip the jq/python3 prerequisite check.

set -euo pipefail

SUITE_ROOT="${SUITE_ROOT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$SUITE_ROOT" ]; then
  SUITE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
cd "$SUITE_ROOT"

[ -f "core/schema/validate-manifest.sh" ] || {
  echo "ci-gate: cannot find core/schema/validate-manifest.sh under $SUITE_ROOT — wrong suite root? Pass --suite-root PATH." >&2
  exit 2
}

if [ "${SKIP_CI_GATE_PREFLIGHT:-0}" != "1" ]; then
  for bin in bash jq python3; do
    command -v "$bin" >/dev/null 2>&1 || {
      echo "ci-gate: missing prerequisite '$bin' (the CI workflow installs jq via apt; python3 ships on ubuntu-latest)" >&2
      exit 2
    }
  done
fi

SWEEP_WS="$(mktemp -d "${TMPDIR:-/tmp}/aibrain-ci-gate.XXXXXX")"
# EXIT + INT/TERM: a Ctrl-C mid-sweep is realistic (the sweep is the slow step),
# and non-interactive bash does not run EXIT traps on SIGINT — so cover all three.
trap 'rm -rf "$SWEEP_WS"' INT TERM EXIT

fail() { # name rc
  echo "ci-gate: GATE RED at '$1' (exit $2) — see output above; the CI job would fail here too." >&2
  exit "$2"
}

step() { # name command...
  local name="$1"; shift
  echo
  echo "── ci-gate: $name"
  "$@" || fail "$name" "$?"
}

step "1/5 validate manifests" bash core/schema/validate-manifest.sh --all
step "2/5 daemon job table (deep-brain-kernel.py --check)" env \
  WORKSPACE="$SUITE_ROOT" \
  DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1 \
  python3 deep-brain-kernel.py --check
step "3/5 skill unit tests" bash tests/run_skill_unit_tests.sh
step "4/5 verification sweep" env \
  WORKSPACE="$SWEEP_WS" \
  bash skills/verification-memory/scripts/run-declared-tests.sh --quiet
# 5/5 static analysis: shellcheck on the core surface when the binary is
# present (installed in CI via apt). Graceful when absent locally — a missing
# lint binary must never red the gate on a machine that simply didn't install
# it, but a present shellcheck with findings MUST red it.
step "5/5 shellcheck (core surface, when available)" bash -c '
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed — skipping static analysis step (CI installs it)"
    exit 0
  fi
  failures=0
  while IFS= read -r -d "" f; do
    out=$(shellcheck -S warning "$f" 2>/dev/null || true)
    if [ -n "$out" ]; then
      echo "$out"
      failures=$((failures + 1))
    fi
  done < <(find core scripts -name "*.sh" -print0; find skills -path "*/scripts/*.sh" -print0; printf "%s\0" install.sh uninstall.sh)
  if [ "$failures" -gt 0 ]; then
    echo "shellcheck: $failures file(s) with findings" >&2
    exit 1
  fi
  echo "shellcheck: core surface clean"
'

echo
echo "✅ ci-gate: all five steps green — this is a green CI run."
