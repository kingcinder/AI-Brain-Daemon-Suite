#!/bin/bash
# Unit: acc-error get-lessons surfaces lesson text from acc-state patterns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
# Support common shapes used by get-lessons (lessons / patterns)
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{
  "resolved": {
    "timeout-retry": {
      "context": "network",
      "count": 3,
      "daysClear": 40,
      "lesson": {"summary": "retry once with backoff", "action": "backoff"}
    }
  }
}
EOF
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/acc-error-memory/scripts/get-lessons.sh")
echo "$OUT" | grep -qi 'timeout-retry'
echo "$OUT" | grep -qiE 'Lessons Learned|retry once with backoff|backoff'
J=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/acc-error-memory/scripts/get-lessons.sh" --json)
echo "$J" | jq -e '."timeout-retry".count == 3' >/dev/null
echo "PASS: acc-error get-lessons"
