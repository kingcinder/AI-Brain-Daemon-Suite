#!/bin/bash
# install.sh — Set up heartbeat-memory for Hermes Agent
# Usage: ./install.sh [--with-cron] [--wake-hour H] [--sleep-hour H]

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
WAKE_HOUR=7
SLEEP_HOUR=23
WITH_CRON=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --with-cron) WITH_CRON=true; shift ;;
    --wake-hour) WAKE_HOUR="$2"; [[ "$WAKE_HOUR" =~ ^[0-9]+$ ]] || { echo "❌ --wake-hour must be an integer"; exit 1; }; shift 2 ;;
    --sleep-hour) SLEEP_HOUR="$2"; [[ "$SLEEP_HOUR" =~ ^[0-9]+$ ]] || { echo "❌ --sleep-hour must be an integer"; exit 1; }; shift 2 ;;
    *) shift ;;
  esac
done

echo "💓 Installing heartbeat-memory..."
echo ""

mkdir -p "$WORKSPACE/memory"

STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "Creating initial heartbeat state..."
  STATE_FILE="$STATE_FILE" WAKE_HOUR="$WAKE_HOUR" SLEEP_HOUR="$SLEEP_HOUR" python3 -c "import os

import json
wake_hour = int(os.environ['WAKE_HOUR'])
sleep_hour = int(os.environ['SLEEP_HOUR'])
state = {
    'version': '1.0',
    'lastUpdated': '',
    'lastBeat': None,
    'beatCount': 0,
    'lastChosenAction': None,
    'lastChosenAt': None,
    'actionHistory': [],
    'circadian': {'wakeHour': wake_hour, 'sleepHour': sleep_hour},
    'options': {
        'project_work':       {'weight': 1.0, 'lastDone': None, 'cooldownMinutes': 0,   'label': 'Work on an unfinished project you asked for'},
        'own_projects':       {'weight': 0.8, 'lastDone': None, 'cooldownMinutes': 0,   'label': 'Work on a self-directed project'},
        'social_media':       {'weight': 0.6, 'lastDone': None, 'cooldownMinutes': 120, 'label': 'Check AI social media (e.g. Moltbook)'},
        'social_interaction': {'weight': 0.6, 'lastDone': None, 'cooldownMinutes': 90,  'label': 'Reach out to / respond to another known AI agent'},
        'dreaming':           {'weight': 0.5, 'lastDone': None, 'cooldownMinutes': 240, 'label': 'Dream: consolidate and integrate recent learnings'},
        'idle':               {'weight': 0.2, 'lastDone': None, 'cooldownMinutes': 0,   'label': 'Stay quiet, nothing urgent'}
    },
    'projects': []
}
with open(os.environ['STATE_FILE'], 'w') as f:
    json.dump(state, f, indent=2)
"
  echo "✅ Created $STATE_FILE"
else
  echo "✅ State file already exists"
fi

chmod +x "$SKILL_DIR/scripts/"*.sh
echo "✅ Scripts are executable"

"$SKILL_DIR/scripts/sync-state.sh"

if [ "$WITH_CRON" = true ]; then
  echo ""
  echo "Setting up Hermes cron job..."
  if ! command -v hermes &> /dev/null; then
    echo "⚠️  'hermes' not in PATH. Add this cron job manually:"
    echo ""
    echo "hermes cron create '7,37 * * * *' '💓 Run heartbeat: $SKILL_DIR/scripts/beat.sh, then act on whatever it tells you to, then run $SKILL_DIR/scripts/log-action.sh when done.' --name heartbeat"
  else
    echo "   Creating heartbeat..."
    hermes cron create '7,37 * * * *' "💓 Run heartbeat: $SKILL_DIR/scripts/beat.sh. Read what it tells you to consider doing, decide whether to act (skip if mid-task or it doesn't make sense right now), then run $SKILL_DIR/scripts/log-action.sh --action <id> --note \"...\" once you've actually done something or decided to skip." --name heartbeat 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
  fi
  echo ""
  echo "   (Offset :07/:37 to avoid colliding with the other brain-suite skills'"
  echo "    cron slots, which sit at :00/:05/:10/:15/:20/:30/:45.)"
fi

echo ""
echo "┌──────────────────────────────────────────────────────┐"
echo "│  💓 Pulse — autonomous initiative, on a 30-min timer  │"
echo "└──────────────────────────────────────────────────────┘"
echo ""
echo "Usage:"
echo "  $SKILL_DIR/scripts/beat.sh                 # decide what to do right now"
echo "  $SKILL_DIR/scripts/projects.sh add --title \"...\" --type unfinished"
echo "  $SKILL_DIR/scripts/get-state.sh"
echo ""
[ "$WITH_CRON" != true ] && echo "TIP: ./install.sh --with-cron to wire up the 30-minute timer"
echo "Done! 💓"
