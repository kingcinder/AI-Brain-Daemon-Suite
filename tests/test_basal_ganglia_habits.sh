#!/bin/bash
# Unit: basal-ganglia get-habits lists named habits from habit-state.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/habit-state.json" << 'EOF'
{
  "habits": [
    {"id":"morning_review","cue":"wake","routine":"review","reward":"clarity","strength":0.8,"category":"workflow","executions":3,"status":"active"}
  ],
  "procedures": [],
  "suppressions": []
}
EOF
J=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/basal-ganglia-memory/get-habits.sh" --json)
echo "$J" | jq -e '.habits[0].id == "morning_review" and .habits[0].strength == 0.8' >/dev/null
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/basal-ganglia-memory/get-habits.sh")
echo "$OUT" | grep -qi 'morning_review'
echo "PASS: basal-ganglia get-habits"
