#!/bin/bash
# Unit: heartbeat get-state reports beatCount and circadian hours.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/heartbeat-state.json" << 'EOF'
{
  "beatCount": 42,
  "lastBeat": "2026-07-20T12:00:00Z",
  "lastChosenAction": "idle",
  "circadian": {"wakeHour": 7, "sleepHour": 23},
  "projects": [{"name":"p1","status":"active"}],
  "actionHistory": []
}
EOF
J=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/heartbeat-memory/scripts/get-state.sh" --json)
echo "$J" | jq -e '.beatCount == 42 and .circadian.wakeHour == 7' >/dev/null
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/heartbeat-memory/scripts/get-state.sh")
echo "$OUT" | grep -q '42'
echo "$OUT" | grep -q 'wake 7'
echo "PASS: heartbeat get-state"
