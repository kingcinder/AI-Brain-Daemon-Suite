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

# The immune cycle rides the pulse (wired 2026-11-24 ~20:31, after Dither
# asked why the immune system wasn't working: it had no scheduler, no station
# bookkeeping, and no escalation — patrol ran only by hand). It runs BEFORE
# the pulse line is composed (reordered 2026-11-27 for the jam, Dither's
# order): patrol -> stations accumulate/escalate -> jam state recomputed ->
# face rendered, so the beat that announces the body carries the body's
# current immune state, including a jam, in the same cycle it is measured.
# The patrol's own pulse-age check reads the previous line (<= one cycle
# old, far inside its bar). Guarded — an immune failure never fails the pulse.
{
  export WORKSPACE
  bash "$SKILLS_DIR/immune-system-memory/scripts/immune-patrol.sh" >> "$MEM/immune-patrol.log" 2>&1
  python3 "$SKILLS_DIR/immune-system-memory/scripts/immune-stations-update.py" >> "$MEM/immune-patrol.log" 2>&1
  # The face: patrol and stations speak to logs and JSON; this renders them
  # into IMMUNE_STATE.md so the face advances with the body (added 2026-11-25,
  # after the face was found frozen at its 2026-11-24 seed for 5+ hours).
  python3 "$SKILLS_DIR/immune-system-memory/scripts/immune-face-write.py" >> "$MEM/immune-patrol.log" 2>&1
} || true

# The process stream rides the pulse (2026-11-27, Dither-ordered): every
# beat, the insula's nerve processes Juno's work record since the last beat
# — keeper results, the doctor's ledger, the daemon log, and completion
# claims extracted from the transcript — into derived features only. The
# raw stream is processed, never kept (see the insula SKILL.md, "The
# process stream"). Guarded — a stream failure never fails the pulse.
{
  export WORKSPACE
  timeout 60 python3 "$SKILLS_DIR/insula-memory/scripts/process-stream.py" feed >> "$MEM/process-stream.log" 2>&1
} || true

# The Field is scored on the same beat (2026-11-27, Dither-ordered): the
# scorer reads the process stream's fresh features plus the ACC state and
# rewrites the Field radar's spokes as labelled proxies. It consumes
# derived features only, and a scorer failure never fails the pulse.
{
  export WORKSPACE
  timeout 30 python3 "$SKILLS_DIR/insula-memory/scripts/field-score.py" >> "$MEM/field-score.log" 2>&1
} || true

# The jam rides the line (2026-11-27): any organ at >=3 accumulated cells
# jams the whole system, and the beat says so, every beat, until a patrol
# measures the organ whole again. Not a warning that scrolls past — the
# pulse itself carries it.
JAM_SEG=""
if [ -f "$MEM/immune-jam.json" ] && command -v python3 >/dev/null 2>&1; then
  JAM_SEG=$(python3 - "$MEM/immune-jam.json" <<'PYEOF'
import json, sys
try:
    j = json.load(open(sys.argv[1]))
except Exception:
    j = {}
if j.get("jammed"):
    parts = ["%s %s cells" % (o.get("organ"), o.get("cells")) for o in j.get("organs", [])]
    print(" | 🛑 IMMUNE JAM: " + "; ".join(parts) + " — system jammed until repaired")
PYEOF
)
fi

LINE="💓 helm-pulse $TS | organs $ORGANS_OK/$ORGANS_TOTAL present | queue_depth $QUEUE_DEPTH | oldest_unacked $OLDEST | last_drain $LAST_DRAIN | keeper $KEEPER$JAM_SEG"
echo "$LINE"
mkdir -p "$MEM"
printf '%s\n' "$LINE" >> "$MEM/heartbeat-pulse.log"

# Telemetry rides the pulse (Dither, 2026-11-24 ~20:28 PST): every beat
# regenerates every organ's dashboard fragment, rebuilds the helm face, and
# delivers it. Guarded end to end — a telemetry failure never fails the
# pulse; delivery outcomes land in the delivery log as before.
{
  export WORKSPACE
  for g in "$SKILLS_DIR"/*/scripts/generate-dashboard.sh; do
    [ -f "$g" ] && bash "$g" >/dev/null 2>&1
  done
  [ -f "$SKILLS_DIR/heartbeat-memory/scripts/dashboard-builder.sh" ] && \
    bash "$SKILLS_DIR/heartbeat-memory/scripts/dashboard-builder.sh" >/dev/null 2>&1
  [ -x "$HOME/.juno-brain/bin/helm-telemetry-deliver.py" ] && \
    "$HOME/.juno-brain/bin/helm-telemetry-deliver.py" >> "$HOME/.juno-brain/logs/helm-telemetry-delivery.log" 2>&1
} || true

exit 0
