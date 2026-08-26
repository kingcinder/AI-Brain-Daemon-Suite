#!/bin/bash
# rollback-learning.sh — Rollback Learning: reads rollback history and produces
# a structured lessons-learned summary that can be injected into the LLM
# proposal generator prompt. This closes the feedback loop so the model
# learns from past failures instead of repeating them.
#
# Usage:
#   rollback-learning.sh [--workspace PATH] [--limit N] [--json]
# Env: WORKSPACE

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
LIMIT=10
JSON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

DEPLOY_DIR="$WORKSPACE/memory/self-mod/deploys"

# Collect rollback records (most recent first)
ROLLBACKS=()
if [ -d "$DEPLOY_DIR" ]; then
  while IFS= read -r -d '' f; do
    if jq -e '.rolled_back == true' "$f" >/dev/null 2>&1; then
      ROLLBACKS+=("$f")
    fi
  done < <(find "$DEPLOY_DIR" -name '*.json' -type f -printf '%T@ %p\0' 2>/dev/null | sort -rz | cut -d' ' -f2- | head -n "$LIMIT" -z)
fi

# Also check the rollback history JSONL if it exists
HISTORY="$WORKSPACE/memory/self-mod/rollback-history.jsonl"
if [ -f "$HISTORY" ]; then
  while IFS= read -r line; do
    # Extract the deploy record path from history entries
    pid=$(echo "$line" | jq -r '.proposal_id // empty' 2>/dev/null)
    if [ -n "$pid" ] && [ -f "$DEPLOY_DIR/${pid}.json" ]; then
      ROLLBACKS+=("$DEPLOY_DIR/${pid}.json")
    fi
  done < <(tail -n "$LIMIT" "$HISTORY" 2>/dev/null)
fi

# Deduplicate
declare -A SEEN
UNIQUE=()
for f in "${ROLLBACKS[@]}"; do
  pid=$(jq -r '.proposal_id // empty' "$f" 2>/dev/null)
  if [ -n "$pid" ] && [ -z "${SEEN[$pid]:-}" ]; then
    SEEN[$pid]=1
    UNIQUE+=("$f")
  fi
done

# Build lessons summary
LESSONS="[]"
if [ ${#UNIQUE[@]} -gt 0 ]; then
  LESSONS=$(printf '%s\n' "${UNIQUE[@]}" | head -n "$LIMIT" | while IFS= read -r f; do
    jq -c '{
      proposal_id: (.proposal_id // "unknown"),
      module: (.module // "unknown"),
      target: ((.target_paths // [])[0] // "unknown"),
      reason: (.rollback_reason // "unknown"),
      rolled_back_at: (.rollback_at // "unknown"),
      error_summary: (.monitor.status // "rolled_back")
    }' "$f" 2>/dev/null
  done | jq -s '.' 2>/dev/null || echo '[]')
fi

# Count failure reasons for pattern detection
REASON_COUNTS=$(echo "$LESSONS" | jq -c '
  [.[] | .reason] | group_by(.) | map({
    reason: .[0],
    count: length
  }) | sort_by(-.count)
' 2>/dev/null || echo '[]')

# Identify most-failed modules
MODULE_COUNTS=$(echo "$LESSONS" | jq -c '
  [.[] | .module] | group_by(.) | map({
    module: .[0],
    rollbacks: length
  }) | sort_by(-.rollbacks)
' 2>/dev/null || echo '[]')

# Build the lessons text for LLM injection
if [ "$JSON" -eq 1 ]; then
  jq -nc \
    --argjson lessons "$LESSONS" \
    --argjson reasons "$REASON_COUNTS" \
    --argjson modules "$MODULE_COUNTS" \
    --arg total "${#UNIQUE[@]}" \
    '{
      total_rollbacks: ($total | tonumber),
      recent_rollbacks: $lessons,
      failure_patterns: $reasons,
      most_failed_modules: $modules,
      advice: [
        "Do NOT target modules with repeated rollbacks unless the root cause is clear",
        "Avoid the same failure patterns listed above",
        "Prefer incremental changes over large rewrites",
        "If a module has >3 rollbacks, suggest a different approach or architecture change"
      ]
    }'
else
  echo "=== Rollback Learning Summary ==="
  echo "Total rollbacks analyzed: ${#UNIQUE[@]}"
  echo ""
  if [ "${#UNIQUE[@]}" -gt 0 ]; then
    echo "Most common failure reasons:"
    echo "$REASON_COUNTS" | jq -r '.[] | "  - \(.reason): \(.count) times"' 2>/dev/null
    echo ""
    echo "Most failed modules:"
    echo "$MODULE_COUNTS" | jq -r '.[] | "  - \(.module): \(.rollbacks) rollbacks"' 2>/dev/null
    echo ""
    echo "Recent rollback details:"
    echo "$LESSONS" | jq -r '.[] | "  [\(.proposal_id)] \(.module) — \(.reason) (at \(.rolled_back_at))"' 2>/dev/null
  else
    echo "No rollbacks recorded yet."
  fi
  echo ""
  echo "Advice for proposal generator:"
  echo "  - Do NOT target modules with repeated rollbacks unless the root cause is clear"
  echo "  - Avoid the same failure patterns listed above"
  echo "  - Prefer incremental changes over large rewrites"
  echo "  - If a module has >3 rollbacks, suggest a different approach or architecture change"
fi
