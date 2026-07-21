#!/bin/bash
# log-event.sh — Append a basal-ganglia event to brain-events.jsonl
#
# Usage:
#   ./log-event.sh <event> [key=value ...]
#
# Examples:
#   ./log-event.sh encoding habits_found=2 reinforced=1 new=1
#   ./log-event.sh decay decayed=4 below_threshold=1
#   ./log-event.sh reinforce habit=habit_001 strength=0.78
#   ./log-event.sh suppress pattern=sup_003 strength=0.6
#
# Events append to $WORKSPACE/memory/brain-events.jsonl as:
#   {"ts":"2026-06-15T10:00:00Z","type":"basal-ganglia","event":"reinforce","habit":"habit_001","strength":0.78}
#
# Environment:
#   WORKSPACE - OpenClaw workspace directory (default: ~/.openclaw/workspace)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
LOG_FILE="$WORKSPACE/memory/brain-events.jsonl"

EVENT="$1"
shift || true

if [ -z "$EVENT" ]; then
    echo "Usage: log-event.sh <event> [key=value ...]"
    echo ""
    echo "Examples:"
    echo "  log-event.sh encoding habits_found=2 reinforced=1 new=1"
    echo "  log-event.sh decay decayed=4 below_threshold=1"
    echo "  log-event.sh reinforce habit=habit_001 strength=0.78"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - "$EVENT" "$NOW" "$LOG_FILE" "$@" << 'PYTHON'
import json
import sys

event = sys.argv[1]
ts = sys.argv[2]
log_file = sys.argv[3]
pairs = sys.argv[4:]

entry = {"ts": ts, "type": "basal-ganglia", "event": event}

for pair in pairs:
    if "=" not in pair:
        continue
    key, _, raw = pair.partition("=")

    # Try to coerce numbers/booleans, otherwise keep as string
    value = raw
    if raw.lower() in ("true", "false"):
        value = raw.lower() == "true"
    else:
        try:
            if "." in raw:
                value = float(raw)
            else:
                value = int(raw)
        except ValueError:
            value = raw

    entry[key] = value

with open(log_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

print(f"🎯 Logged event: {event}")
for k, v in entry.items():
    if k not in ("ts", "type", "event"):
        print(f"   {k}: {v}")
PYTHON
