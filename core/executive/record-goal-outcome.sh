#!/bin/bash
# record-goal-outcome.sh — ROADMAP M4 goal-outcome recorder.
#
# Closes the goal loop: given an outcome (success/failure) for a spawn job
# that was injected with active executive goals, marks the matching PFC
# goals complete (success) or failed (failure), appends to a persistent
# outcome log, and on failure feeds ACC error memory so the lesson enters
# error calibration.
#
# Also supports deferral of stale goals (active goals past their deadline or
# untouched for N days).
#
# Status-flip relevance guard: when --task is supplied, a goal's status is
# only flipped when its description shares meaningful words with the task
# text (the job that succeeded/failed was actually about that goal).
# Without --task, status is always flipped (direct/manual use).
#
# Usage:
#   record-goal-outcome.sh outcome --goal-description "desc" --outcome success|failure \
#       [--task TEXT] [--job NAME] [--evidence TEXT]
#   record-goal-outcome.sh outcome --goal-id <id> --outcome success|failure ...
#   record-goal-outcome.sh defer-stale --days N
#
# Writes:
#   $WORKSPACE/memory/pfc-state.json        (goal status: complete / failed / deferred)
#   $WORKSPACE/memory/executive/goal-outcomes.jsonl   (append-only outcome log)
# On a flipped failure also:
#   $WORKSPACE/memory/acc-state.json        (via acc-error-memory log-error.sh)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PFC="$WORKSPACE/memory/pfc-state.json"
OUT_LOG="$WORKSPACE/memory/executive/goal-outcomes.jsonl"
ACC_LOG="$ROOT/skills/acc-error-memory/scripts/log-error.sh"
if [ ! -x "$ACC_LOG" ]; then
  ACC_LOG="$WORKSPACE/skills/acc-error-memory/scripts/log-error.sh"
fi

mkdir -p "$WORKSPACE/memory/executive"
[ -f "$PFC" ] || { echo "record-goal-outcome: no pfc-state.json" >&2; exit 1; }

# flock-guarded PFC read-modify-write (same pattern as log-error.sh): PFC is
# written concurrently by propose-goals.sh / deploy-proposal.sh.
exec 200>"$PFC.lock"
flock 200

CMD="${1:-}"; shift 1 2>/dev/null || true
GOAL_ID=""; GOAL_DESC=""; OUTCOME=""; JOB=""; EVIDENCE=""; DAYS=""; TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goal-id) GOAL_ID="$2"; shift 2 ;;
    --goal-description) GOAL_DESC="$2"; shift 2 ;;
    --outcome) OUTCOME="$2"; shift 2 ;;
    --job) JOB="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    *) shift ;;
  esac
done

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

outcome() {
  [ -z "$GOAL_ID" ] && [ -z "$GOAL_DESC" ] && { echo "usage: outcome --goal-id <id>|--goal-description <desc> --outcome success|failure" >&2; exit 1; }
  case "$OUTCOME" in
    success|failure) ;;
    *) echo "outcome must be success or failure" >&2; exit 1 ;;
  esac

  # Resolve id from description, or validate a directly-supplied id exists.
  if [ -z "$GOAL_ID" ]; then
    GOAL_ID=$(jq -r --arg d "$GOAL_DESC" \
      '[.goals[] | select(.status=="active" and .description==$d)][0].id // empty' "$PFC")
    [ -n "$GOAL_ID" ] || { echo "record-goal-outcome: no active goal matches '$GOAL_DESC'" >&2; exit 1; }
  else
    jq -e --arg id "$GOAL_ID" '.goals[] | select(.id==$id)' "$PFC" >/dev/null 2>&1 \
      || { echo "record-goal-outcome: no goal with id '$GOAL_ID'" >&2; exit 1; }
  fi

  # Relevance guard: flip status only when the task shares words with the goal.
  FLIP=1
  if [ -n "$TASK" ]; then
    FLIP=$(python3 - "$GOAL_DESC" "$TASK" << 'PY'
import re, sys
STOP = {'a','an','the','to','on','of','for','and','or','your','you','is','are','it',
        'in','with','at','this','that','do','doing','run','the'}
def words(t):
    return {w for w in re.findall(r"[a-z0-9]+", t.lower()) if w not in STOP and len(w) > 2}
d, t = sys.argv[1], sys.argv[2]
print(1 if (words(d) & words(t)) else 0)
PY
)
  fi

  if [ "$FLIP" = "1" ]; then
    NEW_STATUS="complete"; [ "$OUTCOME" = "failure" ] && NEW_STATUS="failed"
    TS_FIELD="completedAt"; [ "$OUTCOME" = "failure" ] && TS_FIELD="failedAt"
    jq --arg id "$GOAL_ID" --arg status "$NEW_STATUS" --arg ts "$NOW" --arg tsfield "$TS_FIELD" \
      '(.goals[] | select(.id==$id)) as $g |
       ($g | .status = $status | .[$tsfield] = $ts | .outcome = ($status|tostring)) as $updated |
       (.goals | map(if .id==$id then $updated else . end)) as $newgoals |
       .goals = $newgoals | .lastUpdated = $ts' \
      "$PFC" > "$PFC.tmp" && mv "$PFC.tmp" "$PFC"
  fi

  printf '%s\n' "$(jq -nc --arg id "$GOAL_ID" --arg desc "$GOAL_DESC" --arg outcome "$OUTCOME" \
    --arg job "$JOB" --arg evidence "$EVIDENCE" --arg flipped "$FLIP" --arg ts "$NOW" \
    '{ts:$ts, goal_id:$id, description:$desc, outcome:$outcome, job:$job, evidence:$evidence, flipped:($flipped=="1")}')" \
    >> "$OUT_LOG"

  echo "record-goal-outcome: goal $GOAL_ID outcome=$OUTCOME (flipped=$FLIP job=$JOB)"

  if [ "$OUTCOME" = "failure" ] && [ "$FLIP" = "1" ] && [ -x "$ACC_LOG" ]; then
    PATTERN="goal_failed:$(echo "$GOAL_DESC" | head -c 60)"
    WORKSPACE="$WORKSPACE" bash "$ACC_LOG" \
      --pattern "$PATTERN" \
      --context "Goal '${GOAL_DESC}' marked failed after job ${JOB:-unknown}${EVIDENCE:+: $EVIDENCE}" \
      --mitigation "re-scope or retire the goal; verify prerequisites before re-attempting" \
      >/dev/null 2>&1 || true
  fi
}

defer_stale() {
  DAYS="${DAYS:-30}"
  # Active goals past their deadline, or with no deadline and untouched for N days
  python3 - "$PFC" "$DAYS" "$NOW" << 'PY'
import json, sys
from datetime import datetime, timezone
pfc_path, days, now = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(pfc_path) as f:
    pfc = json.load(f)
now_dt = datetime.fromisoformat(now.replace("Z", "+00:00"))
deferred = []
for g in pfc.get("goals", []):
    if g.get("status") != "active":
        continue
    dl = g.get("deadline") or ""
    stale = False
    if dl:
        try:
            if datetime.fromisoformat(dl.replace("Z", "+00:00")) < now_dt:
                stale = True
        except ValueError:
            stale = False
    else:
        created = g.get("createdAt") or ""
        if created:
            try:
                if (now_dt - datetime.fromisoformat(created.replace("Z", "+00:00"))).days >= days:
                    stale = True
            except ValueError:
                stale = False
    if stale:
        g["status"] = "deferred"
        g["deferredAt"] = now
        deferred.append(g.get("id"))
pfc["lastUpdated"] = now
with open(pfc_path, "w") as f:
    json.dump(pfc, f, indent=2, sort_keys=True)
print("\n".join(deferred))
PY
}

case "$CMD" in
  outcome) outcome ;;
  defer-stale) defer_stale ;;
  *) echo "usage: record-goal-outcome.sh {outcome|defer-stale} [...]" >&2; exit 1 ;;
esac
