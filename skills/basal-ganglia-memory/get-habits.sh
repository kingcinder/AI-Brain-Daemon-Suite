#!/bin/bash
# get-habits.sh — Read current habit state (table or JSON)
#
# Usage:
#   get-habits.sh                       # Full table: habits, procedures, suppressions
#   get-habits.sh --json                # Raw habit-state.json
#   get-habits.sh --type habits         # Only show habits
#   get-habits.sh --type procedures     # Only show procedures
#   get-habits.sh --type suppressions   # Only show suppressions
#   get-habits.sh --status chunked      # Filter by status (chunked|active|forming|candidate)
#   get-habits.sh --category workflow   # Filter by category
#
# Environment:
#   WORKSPACE - OpenClaw workspace directory (default: ~/.hermes/workspace)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/habit-state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ No habit state found at $STATE_FILE"
    echo "   Run install.sh first."
    exit 1
fi

JSON_OUTPUT=false
TYPE_FILTER=""
STATUS_FILTER=""
CATEGORY_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) JSON_OUTPUT=true; shift ;;
        --type) TYPE_FILTER="$2"; shift 2 ;;
        --status) STATUS_FILTER="$2"; shift 2 ;;
        --category) CATEGORY_FILTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ "$JSON_OUTPUT" = true ]; then
    cat "$STATE_FILE"
    exit 0
fi

export GH_STATE_FILE="$STATE_FILE"
export GH_TYPE_FILTER="$TYPE_FILTER"
export GH_STATUS_FILTER="$STATUS_FILTER"
export GH_CATEGORY_FILTER="$CATEGORY_FILTER"

python3 << 'PYTHON'
import json
import os

STATE_FILE = os.environ["GH_STATE_FILE"]
TYPE_FILTER = os.environ["GH_TYPE_FILTER"]
STATUS_FILTER = os.environ["GH_STATUS_FILTER"]
CATEGORY_FILTER = os.environ["GH_CATEGORY_FILTER"]

with open(STATE_FILE) as f:
    state = json.load(f)

habits = state.get("habits", [])
procedures = state.get("procedures", [])
suppressions = state.get("suppressions", [])

def status_for(strength):
    if strength >= 0.7:
        return "chunked"
    if strength >= 0.4:
        return "active"
    if strength >= 0.2:
        return "forming"
    return "candidate"

def bar(value, width=20):
    filled = int(round(value * width))
    filled = max(0, min(width, filled))
    return "█" * filled + "░" * (width - filled)

STATUS_EMOJI = {"chunked": "🟢", "active": "🟡", "forming": "🟠", "candidate": "⚪"}

def matches(strength, category, item_category):
    if STATUS_FILTER and status_for(strength) != STATUS_FILTER:
        return False
    if CATEGORY_FILTER and item_category != CATEGORY_FILTER:
        return False
    return True

last_updated = state.get("lastUpdated") or "never"
decay_last_run = state.get("decayLastRun") or "never"

print("🎯 Basal Ganglia — Habit State")
print("===============================")
print(f"Last updated: {last_updated}")
print(f"Last decay run: {decay_last_run}")
print()

show_habits = not TYPE_FILTER or TYPE_FILTER == "habits"
show_procedures = not TYPE_FILTER or TYPE_FILTER == "procedures"
show_suppressions = not TYPE_FILTER or TYPE_FILTER == "suppressions"

if show_habits:
    rows = [h for h in habits if matches(h.get("strength", 0), h.get("category"), h.get("category"))]
    rows.sort(key=lambda h: h.get("strength", 0), reverse=True)
    print(f"## Habits ({len(rows)}{'/' + str(len(habits)) if len(rows) != len(habits) else ''})")
    print()
    if not rows:
        print("  (none)")
    for h in rows:
        strength = h.get("strength", 0)
        status = h.get("status") or status_for(strength)
        emoji = STATUS_EMOJI.get(status, "•")
        print(f"  {emoji} {h.get('id','?'):<10} [{bar(strength)}] {strength:.2f}  {status:<9} ({h.get('executions',0)} runs, {h.get('category','-')})")
        print(f"      cue:     {h.get('cue','-')}")
        print(f"      routine: {h.get('routine','-')}")
        print(f"      reward:  {h.get('reward','-')}")
        if h.get("tags"):
            print(f"      tags:    {', '.join(h['tags'])}")
        print()

if show_procedures:
    rows = [p for p in procedures if matches(p.get("strength", 0), p.get("category"), p.get("category"))]
    rows.sort(key=lambda p: p.get("strength", 0), reverse=True)
    print(f"## Procedures ({len(rows)}{'/' + str(len(procedures)) if len(rows) != len(procedures) else ''})")
    print()
    if not rows:
        print("  (none)")
    for p in rows:
        strength = p.get("strength", 0)
        status = status_for(strength)
        emoji = STATUS_EMOJI.get(status, "•")
        print(f"  {emoji} {p.get('id','?'):<10} [{bar(strength)}] {strength:.2f}  {status:<9} ({p.get('executions',0)} runs, {p.get('category','-')})")
        print(f"      {p.get('name','-')}")
        steps = p.get("steps", [])
        if steps:
            print(f"      steps: {' → '.join(steps)}")
        print()

if show_suppressions:
    rows = [s for s in suppressions if (not CATEGORY_FILTER) or s.get("category") == CATEGORY_FILTER]
    rows.sort(key=lambda s: s.get("strength", 0), reverse=True)
    print(f"## Suppressions ({len(rows)}{'/' + str(len(suppressions)) if len(rows) != len(suppressions) else ''})")
    print()
    if not rows:
        print("  (none)")
    for s in rows:
        strength = s.get("strength", 0)
        print(f"  🚫 {s.get('id','?'):<10} [{bar(strength)}] {strength:.2f}")
        print(f"      pattern: {s.get('pattern','-')}")
        print(f"      reason:  {s.get('reason','-')}")
        print()
PYTHON
