#!/bin/bash
# test_deep_brain_kernel.sh — Wrapper: runs test_deep_brain_kernel.py with a
# hermetic WORKSPACE (the checkout), mirroring the CI gate's --check env so
# the job-table validation resolves every direct job script under this repo.
#
# Run: bash tests/test_deep_brain_kernel.sh
# Requires: python3 (already in the Suite's dependency set)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export WORKSPACE="$ROOT"
export DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1

python3 tests/test_deep_brain_kernel.py
