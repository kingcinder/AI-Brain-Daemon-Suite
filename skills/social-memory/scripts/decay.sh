#!/bin/bash
# decay.sh — Trust/affinity drift gently toward neutral (0.5) without contact.
# Models distance, not punishment: only relationships untouched for 7+ days move.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/social-state.json"
[ ! -f "$STATE_FILE" ] && { echo "❌ No social state found"; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

NOW="$NOW" STATE_FILE="$STATE_FILE" python3 -c "import os

import json
from datetime import datetime, timezone

state = json.load(open(os.environ['STATE_FILE']))
now = datetime.fromisoformat(os.environ['NOW'].replace('Z', '+00:00'))
changed = 0

for rid, r in state.get('relationships', {}).items():
    last = r.get('lastContact')
    if not last:
        continue
    try:
        last_dt = datetime.fromisoformat(last.replace('Z', '+00:00'))
    except Exception:
        continue
    days = (now - last_dt).total_seconds() / 86400
    if days < 7:
        continue
    for field in ('trust', 'affinity'):
        v = r.get(field, 0.5)
        r[field] = round(v + (0.5 - v) * 0.05, 3)
    changed += 1

state['lastUpdated'] = os.environ['NOW']
with open(os.environ['STATE_FILE'], 'w') as f:
    json.dump(state, f, indent=2)
print(f'🫂 Decayed {changed} relationship(s) untouched for 7+ days toward neutral')
"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
