#!/bin/bash
# reinforce-habit.sh — Manually reinforce, weaken, create, or suppress a habit
#
# Usage:
#   reinforce-habit.sh --list
#       List all habit/procedure/suppression IDs for reference.
#
#   reinforce-habit.sh --id <id> [--type habit|procedure] [--note "..."]
#       Reinforce an existing habit/procedure: strength moves toward 1.0
#       by 12% of remaining headroom, executions += 1, lastFired/lastUsed
#       is set to now, and status is recomputed.
#
#   reinforce-habit.sh --id <id> [--type habit|procedure] --weaken [--note "..."]
#       Negative reinforcement: the routine fired but the outcome was poor.
#       Strength decays by 12% toward 0 instead of toward 1, and status is
#       recomputed. Use this when a chunked habit misfires.
#
#   reinforce-habit.sh --new --cue "<cue>" --routine "<routine>" --reward "<reward>"
#                       [--category <cat>] [--tags "a,b,c"] [--strength <0-1>]
#       Create a new habit. Default initial strength is 0.15 (single
#       observed pattern). Use --strength 0.6 for an explicit request
#       ("always do X"), 0.4 for a behavior observed 3+ times, or 0.3 for
#       a pattern that just completed a successful workflow.
#
#   reinforce-habit.sh --new --type procedure --name "<name>" --steps "step1,step2,..."
#                       [--category <cat>] [--strength <0-1>]
#       Create a new procedure (chunked multi-step workflow).
#
#   reinforce-habit.sh --suppress "<pattern>" --reason "<reason>" [--strength <0-1>]
#       Add a new suppression, or reinforce an existing one with a matching
#       pattern. Default initial strength is 0.6. Suppressions decay much
#       more slowly than habits (see decay-habits.sh) since corrections are
#       meant to stick.
#
# Environment:
#   WORKSPACE - OpenClaw workspace directory (default: ~/.hermes/workspace)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
# reinforce-habit.sh lives at the skill root (alongside log-event.sh),
# with the pipeline internals one level down in scripts/.
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"

exec 200>"$STATE_FILE.lock"
flock 200

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ No habit state found at $STATE_FILE"
    echo "   Run install.sh first."
    exit 1
fi

# ── Argument parsing ──────────────────────────────────────────────────────
MODE=""          # list | reinforce | new | suppress
HABIT_ID=""
ITEM_TYPE="habit"  # habit | procedure
WEAKEN=false
NOTE=""
CUE=""
ROUTINE=""
REWARD=""
CATEGORY=""
TAGS=""
NAME=""
STEPS=""
STRENGTH=""
SUPPRESS_PATTERN=""
REASON=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --list) MODE="list"; shift ;;
        --id) HABIT_ID="$2"; MODE="${MODE:-reinforce}"; shift 2 ;;
        --type) ITEM_TYPE="$2"; shift 2 ;;
        --weaken) WEAKEN=true; shift ;;
        --note) NOTE="$2"; shift 2 ;;
        --new) MODE="new"; shift ;;
        --cue) CUE="$2"; shift 2 ;;
        --routine) ROUTINE="$2"; shift 2 ;;
        --reward) REWARD="$2"; shift 2 ;;
        --category) CATEGORY="$2"; shift 2 ;;
        --tags) TAGS="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --steps) STEPS="$2"; shift 2 ;;
        --strength) STRENGTH="$2"; shift 2 ;;
        --suppress) SUPPRESS_PATTERN="$2"; MODE="suppress"; shift 2 ;;
        --reason) REASON="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Usage:"
    echo "  reinforce-habit.sh --list"
    echo "  reinforce-habit.sh --id <id> [--type habit|procedure] [--weaken] [--note \"...\"]"
    echo "  reinforce-habit.sh --new --cue \"<cue>\" --routine \"<routine>\" --reward \"<reward>\" [--category <cat>] [--tags \"a,b,c\"] [--strength <0-1>]"
    echo "  reinforce-habit.sh --new --type procedure --name \"<name>\" --steps \"step1,step2\" [--category <cat>] [--strength <0-1>]"
    echo "  reinforce-habit.sh --suppress \"<pattern>\" --reason \"<reason>\" [--strength <0-1>]"
    exit 1
fi

export STATE_FILE MODE HABIT_ID ITEM_TYPE WEAKEN NOTE CUE ROUTINE REWARD CATEGORY TAGS NAME STEPS STRENGTH SUPPRESS_PATTERN REASON

RESULT=$(python3 << 'PYTHON'
import json
import os
from datetime import datetime, timezone

STATE_FILE = os.environ["STATE_FILE"]
MODE = os.environ["MODE"]
HABIT_ID = os.environ.get("HABIT_ID", "")
ITEM_TYPE = os.environ.get("ITEM_TYPE", "habit")
WEAKEN = os.environ.get("WEAKEN", "false") == "true"
NOTE = os.environ.get("NOTE", "")
CUE = os.environ.get("CUE", "")
ROUTINE = os.environ.get("ROUTINE", "")
REWARD = os.environ.get("REWARD", "")
CATEGORY = os.environ.get("CATEGORY", "") or "general"
TAGS = os.environ.get("TAGS", "")
NAME = os.environ.get("NAME", "")
STEPS = os.environ.get("STEPS", "")
STRENGTH_RAW = os.environ.get("STRENGTH", "")
SUPPRESS_PATTERN = os.environ.get("SUPPRESS_PATTERN", "")
REASON = os.environ.get("REASON", "")

REINFORCE_RATE = 0.12
NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(STATE_FILE) as f:
    state = json.load(f)

habits = state.setdefault("habits", [])
procedures = state.setdefault("procedures", [])
suppressions = state.setdefault("suppressions", [])


def clamp(v):
    return max(0.0, min(1.0, v))


def status_for(strength):
    if strength >= 0.7:
        return "chunked"
    if strength >= 0.4:
        return "active"
    if strength >= 0.2:
        return "forming"
    return "candidate"


def next_id(items, prefix):
    max_n = 0
    for it in items:
        try:
            n = int(it["id"].replace(prefix, ""))
            max_n = max(max_n, n)
        except (KeyError, ValueError):
            pass
    return f"{prefix}{max_n + 1:03d}"


output = {}

if MODE == "list":
    output["habits"] = [
        {"id": h["id"], "cue": h.get("cue", ""), "strength": h.get("strength", 0), "status": h.get("status") or status_for(h.get("strength", 0))}
        for h in habits
    ]
    output["procedures"] = [
        {"id": p["id"], "name": p.get("name", ""), "strength": p.get("strength", 0)}
        for p in procedures
    ]
    output["suppressions"] = [
        {"id": s["id"], "pattern": s.get("pattern", ""), "strength": s.get("strength", 0)}
        for s in suppressions
    ]
    output["action"] = "list"

elif MODE == "reinforce":
    collection = habits if ITEM_TYPE == "habit" else procedures
    item = next((x for x in collection if x["id"] == HABIT_ID), None)
    if item is None:
        output["error"] = f"No {ITEM_TYPE} found with id '{HABIT_ID}'"
    else:
        old_strength = item.get("strength", 0)
        if WEAKEN:
            new_strength = clamp(old_strength - old_strength * REINFORCE_RATE)
        else:
            new_strength = clamp(old_strength + (1 - old_strength) * REINFORCE_RATE)
        item["strength"] = round(new_strength, 4)
        item["executions"] = item.get("executions", 0) + 1
        time_field = "lastFired" if ITEM_TYPE == "habit" else "lastUsed"
        item[time_field] = NOW
        if ITEM_TYPE == "habit":
            item["status"] = status_for(new_strength)
        if NOTE:
            item["lastNote"] = NOTE

        output["action"] = "weaken" if WEAKEN else "reinforce"
        output["id"] = item["id"]
        output["old_strength"] = round(old_strength, 4)
        output["new_strength"] = item["strength"]
        output["status"] = item.get("status", status_for(new_strength))
        output["executions"] = item["executions"]

elif MODE == "new":
    if ITEM_TYPE == "procedure":
        default_strength = 0.3
        new_strength = clamp(float(STRENGTH_RAW)) if STRENGTH_RAW else default_strength
        item = {
            "id": next_id(procedures, "proc_"),
            "name": NAME or "unnamed procedure",
            "steps": [s.strip() for s in STEPS.split(",") if s.strip()],
            "strength": round(new_strength, 4),
            "executions": 1,
            "lastUsed": NOW,
            "created": NOW,
            "category": CATEGORY,
        }
        procedures.append(item)
        output["action"] = "new_procedure"
        output["id"] = item["id"]
        output["strength"] = item["strength"]
        output["status"] = status_for(item["strength"])
    else:
        default_strength = 0.15
        new_strength = clamp(float(STRENGTH_RAW)) if STRENGTH_RAW else default_strength
        item = {
            "id": next_id(habits, "habit_"),
            "cue": CUE or "(unspecified cue)",
            "routine": ROUTINE or "(unspecified routine)",
            "reward": REWARD or "(unspecified reward)",
            "strength": round(new_strength, 4),
            "executions": 1,
            "lastFired": NOW,
            "created": NOW,
            "category": CATEGORY,
            "tags": [t.strip() for t in TAGS.split(",") if t.strip()],
            "status": status_for(new_strength),
        }
        habits.append(item)
        output["action"] = "new_habit"
        output["id"] = item["id"]
        output["strength"] = item["strength"]
        output["status"] = item["status"]

elif MODE == "suppress":
    default_strength = 0.6
    requested_strength = clamp(float(STRENGTH_RAW)) if STRENGTH_RAW else default_strength

    # Check for an existing suppression with the same pattern (case-insensitive)
    existing = next((s for s in suppressions if s.get("pattern", "").strip().lower() == SUPPRESS_PATTERN.strip().lower()), None)
    if existing:
        old_strength = existing.get("strength", 0)
        new_strength = clamp(old_strength + (1 - old_strength) * REINFORCE_RATE)
        existing["strength"] = round(new_strength, 4)
        existing["lastReinforced"] = NOW
        if REASON:
            existing["reason"] = REASON
        output["action"] = "reinforce_suppression"
        output["id"] = existing["id"]
        output["old_strength"] = round(old_strength, 4)
        output["new_strength"] = existing["strength"]
    else:
        item = {
            "id": next_id(suppressions, "sup_"),
            "pattern": SUPPRESS_PATTERN,
            "strength": round(requested_strength, 4),
            "reason": REASON or "no reason given",
            "created": NOW,
            "lastReinforced": NOW,
        }
        suppressions.append(item)
        output["action"] = "new_suppression"
        output["id"] = item["id"]
        output["strength"] = item["strength"]

state["habits"] = habits
state["procedures"] = procedures
state["suppressions"] = suppressions
state["lastUpdated"] = NOW

if "error" not in output:
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

print(json.dumps(output))
PYTHON
)

# ── Report + side effects ───────────────────────────────────────────────
ACTION=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action','error'))")

if [ "$ACTION" = "error" ]; then
    ERR=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown error'))")
    echo "❌ $ERR"
    exit 1
fi

case "$ACTION" in
    list)
        echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('Habits:')
for h in d['habits']:
    print(f\"  {h['id']:<10} [{h['status']:<9}] strength={h['strength']:.2f}  cue: {h['cue']}\")
print()
print('Procedures:')
for p in d['procedures']:
    print(f\"  {p['id']:<10} strength={p['strength']:.2f}  {p['name']}\")
print()
print('Suppressions:')
for s in d['suppressions']:
    print(f\"  {s['id']:<10} strength={s['strength']:.2f}  {s['pattern']}\")
"
        exit 0
        ;;
    reinforce)
        ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        OLD=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['old_strength'])")
        NEW=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['new_strength'])")
        STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
        EXEC=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['executions'])")
        echo "✅ Reinforced $ID: $OLD → $NEW ($STATUS, $EXEC executions)"
        "$SKILL_DIR/log-event.sh" reinforce id="$ID" old_strength="$OLD" new_strength="$NEW" status="$STATUS" >/dev/null
        ;;
    weaken)
        ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        OLD=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['old_strength'])")
        NEW=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['new_strength'])")
        STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
        echo "⬇️  Weakened $ID: $OLD → $NEW ($STATUS)"
        "$SKILL_DIR/log-event.sh" weaken id="$ID" old_strength="$OLD" new_strength="$NEW" status="$STATUS" >/dev/null
        ;;
    new_habit)
        ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        STRENGTH_OUT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['strength'])")
        STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
        echo "✅ Created new habit $ID (strength $STRENGTH_OUT, $STATUS)"
        "$SKILL_DIR/log-event.sh" new_habit id="$ID" strength="$STRENGTH_OUT" >/dev/null
        ;;
    new_procedure)
        ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        STRENGTH_OUT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['strength'])")
        STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
        echo "✅ Created new procedure $ID (strength $STRENGTH_OUT, $STATUS)"
        "$SKILL_DIR/log-event.sh" new_procedure id="$ID" strength="$STRENGTH_OUT" >/dev/null
        ;;
    new_suppression)
        ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        STRENGTH_OUT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['strength'])")
        echo "🚫 Created new suppression $ID (strength $STRENGTH_OUT)"
        "$SKILL_DIR/log-event.sh" new_suppression id="$ID" strength="$STRENGTH_OUT" >/dev/null
        ;;
    reinforce_suppression)
        ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        OLD=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['old_strength'])")
        NEW=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['new_strength'])")
        echo "🚫 Reinforced suppression $ID: $OLD → $NEW"
        "$SKILL_DIR/log-event.sh" reinforce_suppression id="$ID" old_strength="$OLD" new_strength="$NEW" >/dev/null
        ;;
esac

# Resync state + dashboard
"$SKILL_DIR/scripts/sync-state.sh" >/dev/null 2>&1 || true
