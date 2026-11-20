#!/bin/bash
# helm-pulse.sh — heartbeat, redefined (Dyther decision #4, 2026-11-08).
#
# The heartbeat is a simple liveness/sync pulse — a reminder that Juno is
# still processing the organs and their associated work, that all organs
# are working in sync and the system is "still pumping along." It is NOT
# agent work: no decide-act-log. One status line out, every firing.
#
# The line goes to stdout (the daemon appends it to daemon-job-output.log)
# and to $WORKSPACE/memory/heartbeat-pulse.log. Always exits 0 — a pulse
# reports state; it never fails the daemon.

set -u

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SKILLS_DIR="$WORKSPACE/skills"
MEM="$WORKSPACE/memory"

TS=$(TZ=America/Los_Angeles date +"%Y-%m-%d %H:%M:%S %Z")

# Organ liveness: skill dirs present under the deployed workspace.
ORGANS_TOTAL=0
ORGANS_OK=0
if [ -d "$SKILLS_DIR" ]; then
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    ORGANS_TOTAL=$((ORGANS_TOTAL + 1))
    [ -f "$d/SKILL.md" ] && ORGANS_OK=$((ORGANS_OK + 1))
  done
fi

# Helm queue state, from the keeper's health file.
QUEUE_DEPTH="?"
OLDEST="?"
KEEPER="unknown"
LAST_DRAIN="never"
if [ -f "$MEM/helm-health.json" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 - "$MEM/helm-health.json" <<'PYEOF'
import json, sys, time
try:
    h = json.load(open(sys.argv[1]))
except Exception:
    h = {}
print('QUEUE_DEPTH=%s' % (h.get('queue_depth', '?')))
age = h.get('oldest_unacked_age_s')
print('OLDEST=%s' % ('%ss' % age if age is not None else 'none'))
fresh = (time.time() - h.get('epoch', 0)) < 90
print('KEEPER=%s' % ('ok' if fresh else 'STALE'))
print('LAST_DRAIN=%s' % (h.get('last_result_ts') or 'never'))
PYEOF
)"
fi

LINE="💓 helm-pulse $TS | organs $ORGANS_OK/$ORGANS_TOTAL present | queue_depth $QUEUE_DEPTH | oldest_unacked $OLDEST | last_drain $LAST_DRAIN | keeper $KEEPER"
echo "$LINE"
mkdir -p "$MEM"
printf '%s\n' "$LINE" >> "$MEM/heartbeat-pulse.log"
exit 0
