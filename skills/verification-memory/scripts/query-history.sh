#!/bin/bash
# query-history.sh — Long-term health query over verification-report.jsonl.
#
# The append-only report ledger records one entry per sweep/targeted run. Since
# the ledger gained a per-module breakdown (run-declared-tests.sh writes
# `modules: {owner: {tests, passed, failed}}`), this query can surface trends:
#   * overall pass-rate trend across every recorded run
#   * per-module pass-rate history (last N runs each)
#   * healthiest / unhealthiest region by overall pass rate
#
# Old ledger entries without a `modules` field still contribute to the overall
# trend (their global totals are on every entry) but not to per-module stats —
# surfaced as runs_total vs runs_with_modules.
#
# Usage:
#   query-history.sh [--module <name>] [--limit N] [--min-runs N] [--text]
#
# Options:
#   --module <name>  Restrict per-module stats/history to one module
#   --limit N        History points per module / overall (default 20)
#   --min-runs N     Only rank regions seen in >= N runs (default 1)
#   --text           Human-readable table instead of JSON
#
# Env:
#   WORKSPACE   Defaults to $HOME/.hermes/workspace
#
# Exit code: always 0 (an empty/missing ledger is a valid empty answer).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
REPORT_LOG="$WORKSPACE/memory/verification-report.jsonl"

MODULE_FILTER=""
LIMIT=20
MIN_RUNS=1
TEXT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) MODULE_FILTER="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --min-runs) MIN_RUNS="$2"; shift 2 ;;
        --text) TEXT=1; shift ;;
        *) shift ;;
    esac
done

# Empty / missing ledger → valid empty answer, never a hard error.
if [ ! -f "$REPORT_LOG" ]; then
    echo "{\"generated_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"runs_total\":0,\"runs_with_modules\":0,\"overall\":{\"tests\":0,\"passed\":0,\"failed\":0,\"pass_rate\":null},\"history\":[],\"modules\":[],\"healthiest\":null,\"unhealthiest\":null}"
    exit 0
fi

JQPROG=$(mktemp "${TMPDIR:-/tmp}/vm_query.XXXXXX")
trap 'rm -f "$JQPROG"' EXIT
cat > "$JQPROG" << 'JQEOF'
def pct($p; $t):
  if ($t // 0) > 0 then ($p / $t) else null end;

. as $R
| ($R | map(select(has("modules") and (.modules | type) == "object" and ((.modules | length) > 0)))) as $MR
| {
    generated_at: (now | todateiso8601),
    runs_total: ($R | length),
    runs_with_modules: ($MR | length),
    overall: {
      tests: ($R | map(.totals.tests // 0) | add),
      passed: ($R | map(.totals.passed // 0) | add),
      failed: ($R | map(.totals.failed // 0) | add)
    },
    history: [
      $R[] | {ts: .ts, tests: (.totals.tests // 0), passed: (.totals.passed // 0), failed: (.totals.failed // 0)}
      | . + {pass_rate: pct(.passed; .tests)}
    ],
    modules: (
      [ $MR[] | .ts as $ts | .modules | to_entries[]
        | {module: .key, ts: $ts, tests: (.value.tests // 0), passed: (.value.passed // 0), failed: (.value.failed // 0)} ]
      | group_by(.module)
      | map(
          . as $points
          | {
              module: $points[0].module,
              runs: ($points | length),
              tests: ($points | map(.tests) | add),
              passed: ($points | map(.passed) | add),
              failed: ($points | map(.failed) | add)
            }
          | . + {pass_rate: pct(.passed; .tests)}
          | . + {
              history: [ $points[] | {ts: .ts, tests: .tests, passed: .passed, failed: .failed, pass_rate: pct(.passed; .tests)} ]
            }
        )
      | map(select(.module == $filter or $filter == ""))
      | map(select(.runs >= $minRuns))
      | sort_by(-.pass_rate, .module)
    )
  }
| .overall += {pass_rate: pct(.overall.passed; .overall.tests)}
| .history |= .[-$limit:]
| .modules |= map(. + {history: (.history[-$limit:])})
| .healthiest = (.modules[0] // null)
| .unhealthiest = (.modules[-1] // null)
JQEOF

JSON=$(jq -s --argjson limit "$LIMIT" --arg filter "$MODULE_FILTER" --argjson minRuns "$MIN_RUNS" -f "$JQPROG" "$REPORT_LOG")

if [ "$TEXT" -eq 1 ]; then
    echo "$JSON" | jq -r --argjson limit "$LIMIT" '
      # char-array lookup: some jq builds reject indexing a string literal by a
      # number ("Cannot index string with number"), so index an array instead
      def spark: (map(.pass_rate // 0) | map(((. * 7) | floor) as $i | ["▁","▂","▃","▄","▅","▆","▇","█"][$i]) | join(""));
      "Long-term health (last \($limit) runs)",
      "------------------------------------",
      "Overall: \(.overall.passed)/\(.overall.tests) tests passed (\(((.overall.pass_rate // 0) * 100 | round))%) across \(.runs_total) run(s)",
      "",
      "Per-region pass rate:",
      (.modules[] | "  \(.module): \((.pass_rate * 100 | round))% (\(.passed)/\(.tests), \(.runs) run(s))  \(.history | spark)"),
      "",
      "🏆 Healthiest:   \(.healthiest.module // "n/a") (\(((.healthiest.pass_rate // 0) * 100 | round))%)",
      "🚨 Unhealthiest: \(.unhealthiest.module // "n/a") (\(((.unhealthiest.pass_rate // 0) * 100 | round))%)"
    '
    exit 0
fi

echo "$JSON"
