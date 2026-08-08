#!/bin/bash
# deep-verify.sh — One-command local replay of the weekly "deep verify" CI step.
#
# The Verification Gate's other steps are replayable as scripts/ci-gate.sh.
# This one mirrors the workflow's weekly deep-verify step instead: it drives
# the self-mod proposal pipeline's OWN sandbox gate — core/self-mod/evaluate-proposal.sh
# — against the current tree, so drift that would break a real proposal is
# caught on a cadence (weekly CI), not just when a PR happens to touch the
# self-mod pipeline.
#
# What it does:
#   1. Builds a no-op "probe" proposal (a doc-file write under
#      verification-memory — a mutable, manifest-clean target) in a scratch dir.
#   2. Runs evaluate-proposal.sh --proposal <probe> with the exact semantics
#      the pipeline uses: sandbox suite copy, apply-patch, the verification
#      region's declared-test sweep as the regression gate, and
#      deep-brain-kernel.py --check as the daemon job-table gate.
#   3. The probe has no test coverage and no job-table impact, so it is
#      ACCEPTED if and only if the whole suite is healthy (every declared
#      test green, job table intact). Any drift — a red declared test, a
#      broken/empty job target — rejects the probe, and this script exits 1,
#      exactly like the weekly CI run would fail.
#
# Usage:
#   scripts/deep-verify.sh [--suite-root PATH] [--workspace PATH]
# Env:
#   SUITE_ROOT or --suite-root — repo root to verify; defaults to the parent
#       of this script's directory.
#   WORKSPACE or --workspace    — where evaluate-proposal.sh persists baseline
#       metrics / graduation streak / provenance. Defaults to an isolated
#       mktemp scratch (like CI's runner.temp), so the live brain's
#       ~/.hermes/workspace is never touched; removed on exit.

set -euo pipefail

SUITE_ROOT="${SUITE_ROOT:-}"
WORKSPACE="${WORKSPACE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$SUITE_ROOT" ]; then
  SUITE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
cd "$SUITE_ROOT"

[ -f "core/self-mod/evaluate-proposal.sh" ] || {
  echo "deep-verify: cannot find core/self-mod/evaluate-proposal.sh under $SUITE_ROOT — wrong suite root? Pass --suite-root PATH." >&2
  exit 2
}

for bin in bash jq python3; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "deep-verify: missing prerequisite '$bin'" >&2
    exit 2
  }
done

# Isolated scratch workspace by default (CI mirrors runner.temp); cleanup on
# EXIT + INT/TERM (non-interactive bash skips EXIT traps on SIGINT).
if [ -z "$WORKSPACE" ]; then
  WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/aibrain-deep-verify.XXXXXX")"
  OWN_WS=1
else
  mkdir -p "$WORKSPACE"
  OWN_WS=0
fi

PROBE_WS="$(mktemp -d "${TMPDIR:-/tmp}/aibrain-probe.XXXXXX")"
# Remove the self-created scratch workspace only; a caller-supplied
# --workspace (OWN_WS=0) must survive cleanup untouched. (Note: ${OWN_WS:+…}
# would expand for "0" too, so test the value, not emptiness.)
trap 'rm -rf "$PROBE_WS"; [ "${OWN_WS:-0}" = 1 ] && rm -rf "$WORKSPACE"' INT TERM EXIT

echo "── deep-verify: building no-op probe proposal (target skills/verification-memory/deep-verify-probe.md)"

PID="deep_verify_$(date +%Y%m%dT%H%M%SZ)"
PROBE="$PROBE_WS/$PID.json"
cat > "$PROBE" <<EOF
{
  "proposal_id": "$PID",
  "module": "verification-memory",
  "rationale": "deep-verify: no-op probe — accepted iff every declared test passes and the daemon job table is intact",
  "target_paths": ["skills/verification-memory/deep-verify-probe.md"],
  "content": "# deep-verify probe\n\nAutomated weekly self-mod sandbox gate check. This file is never deployed:\nit exists only inside the evaluation sandbox as a manifest-clean, no-op target.\n"
}
EOF

echo "── deep-verify: running evaluate-proposal.sh sandbox gate (regression sweep + daemon job-table check)"
# Capture stdout (the evaluation JSON) separately from stderr (diagnostics) —
# merging them would feed the log lines into jq below.
ERR_LOG="$PROBE_WS/eval.stderr"
if ! OUT=$(WORKSPACE="$WORKSPACE" bash core/self-mod/evaluate-proposal.sh \
    --proposal "$PROBE" --suite-root "$SUITE_ROOT" 2>"$ERR_LOG"); then
  RC=$?
  echo "deep-verify: evaluate-proposal.sh failed hard (rc=$RC)" >&2
  tail -20 "$ERR_LOG" >&2
  exit 1
fi

ACCEPTED=$(echo "$OUT" | jq -r '.accepted // false')
REASON=$(echo "$OUT" | jq -r '.reason // ""')
GATE_RC=$(echo "$OUT" | jq -r '.regression_exit // .gate_rc // 0')

if [ "$ACCEPTED" = "true" ]; then
  echo "✅ deep-verify: probe ACCEPTED (regression_exit=$GATE_RC) — every declared test passed and the job table is intact."
  exit 0
else
  echo "❌ deep-verify: probe REJECTED — the suite has drifted in a way that would block a real proposal." >&2
  [ -n "$REASON" ] && echo "   reason: $REASON" >&2
  echo "   regression_exit=$GATE_RC" >&2
  echo "$OUT" | jq -c '{accepted, reason, regression_exit, apply}' >&2 2>/dev/null || echo "$OUT" >&2
  exit 1
fi
