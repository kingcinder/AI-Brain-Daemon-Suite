#!/usr/bin/env bash
# decay-sense.sh — Return channels toward baseline (12% per run, every 4h)
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ ! -f "$STATE_FILE" ] && echo "No state file" && exit 0

python3 - "$STATE_FILE" << 'PYTHON'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
with open(path) as f:
    state = json.load(f)

channels = state.get('channels', {})
baseline = state.get('baseline', {})
DECAY_RATE = 0.12

print("🌡️ Insula Decay:")
for ch, current in list(channels.items()):
    base = baseline.get(ch, current)
    delta = (base - current) * DECAY_RATE
    new_val = round(current + delta, 3)
    channels[ch] = new_val
    if abs(delta) > 0.001:
        print(f"   {ch}: {current:+.3f} → {new_val:+.3f} (Δ{delta:+.3f})")

state['channels'] = channels
state['lastUpdated'] = datetime.now(timezone.utc).isoformat()
with open(path, 'w') as f:
    json.dump(state, f, indent=2)
print("✅ Decay complete")
PYTHON

"$SCRIPT_DIR/sync-state.sh" > /dev/null 2>&1 || true
"$SCRIPT_DIR/log-event.sh" decay status=complete
