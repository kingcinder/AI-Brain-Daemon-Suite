#!/bin/bash
# decay-habits.sh — Apply time-based decay to habit/procedure/suppression strengths
#
# Habits & procedures decay 3%/day of inactivity:
#   new_strength = strength * (0.97 ^ days_since_last_fired)
#
# Suppressions decay much more slowly (0.5%/day) — corrections are meant
# to stick:
#   new_strength = strength * (0.995 ^ days_since_last_reinforced)
#
# Runs at most once per day (checks decayLastRun).
#
# Environment:
#   WORKSPACE - Hermes workspace directory (default: ~/.hermes/workspace)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
BACKUP="$WORKSPACE/memory/habit-state.backup.json"
TODAY=$(date -u +%Y-%m-%d)

exec 200>"$STATE_FILE.lock"
flock 200

if [ ! -f "$STATE_FILE" ]; then
    echo "❌ habit-state.json not found at $STATE_FILE"
    echo "   Run install.sh first."
    exit 1
fi

cp "$STATE_FILE" "$BACKUP"

echo "🎯 Basal Ganglia Decay"
echo "======================"
echo "Date: $TODAY"
echo "Habit/procedure decay: 3% per day inactive"
echo "Suppression decay:     0.5% per day since last reinforced"
echo ""

LAST_DECAY=$(STATE_FILE="$STATE_FILE" python3 -c "import os
import json; print(json.load(open(os.environ['STATE_FILE'])).get('decayLastRun') or 'never')" 2>/dev/null || echo "never")
if [ "$LAST_DECAY" = "$TODAY" ]; then
    echo "⏸️  Decay already ran today ($LAST_DECAY). Skipping."
    exit 0
fi

STATE_FILE="$STATE_FILE" \
python3 << 'PYTHON'
import json
import os
from datetime import datetime, date, timezone

STATE_FILE = os.environ["STATE_FILE"]
HABIT_DECAY = 0.97       # 3%/day
SUPPRESSION_DECAY = 0.995  # 0.5%/day
PRUNE_THRESHOLD = 0.2
TODAY = date.today()

with open(STATE_FILE) as f:
    state = json.load(f)


def parse_date(s, fallback):
    if not s:
        return fallback
    try:
        if 'T' in s:
            return datetime.fromisoformat(s.replace('Z', '+00:00')).date()
        return datetime.strptime(s, '%Y-%m-%d').date()
    except (ValueError, TypeError):
        return fallback


def status_for(strength):
    if strength >= 0.7:
        return "chunked"
    if strength >= 0.4:
        return "active"
    if strength >= 0.2:
        return "forming"
    return "candidate"


decayed = 0
prune_candidates = []

# Habits decay from lastFired
for h in state.get('habits', []):
    last = parse_date(h.get('lastFired') or h.get('created'), TODAY)
    days = (TODAY - last).days
    if days > 0:
        old = h.get('strength', 0)
        new = round(old * (HABIT_DECAY ** days), 4)
        if new != old:
            decayed += 1
            print(f"  📉 {h.get('id','?'):<10} habit       {old:.3f} → {new:.3f} ({days}d)")
        h['strength'] = new
        h['status'] = status_for(new)
        if new < PRUNE_THRESHOLD:
            prune_candidates.append((h.get('id', '?'), 'habit', new))

# Procedures decay from lastUsed
for p in state.get('procedures', []):
    last = parse_date(p.get('lastUsed') or p.get('created'), TODAY)
    days = (TODAY - last).days
    if days > 0:
        old = p.get('strength', 0)
        new = round(old * (HABIT_DECAY ** days), 4)
        if new != old:
            decayed += 1
            print(f"  📉 {p.get('id','?'):<10} procedure   {old:.3f} → {new:.3f} ({days}d)")
        p['strength'] = new
        if new < PRUNE_THRESHOLD:
            prune_candidates.append((p.get('id', '?'), 'procedure', new))

# Suppressions decay slowly from lastReinforced
for s in state.get('suppressions', []):
    last = parse_date(s.get('lastReinforced') or s.get('created'), TODAY)
    days = (TODAY - last).days
    if days > 0:
        old = s.get('strength', 0)
        new = round(old * (SUPPRESSION_DECAY ** days), 4)
        if new != old:
            decayed += 1
            print(f"  📉 {s.get('id','?'):<10} suppression {old:.3f} → {new:.3f} ({days}d)")
        s['strength'] = new
        if new < PRUNE_THRESHOLD:
            prune_candidates.append((s.get('id', '?'), 'suppression', new))

state['decayLastRun'] = str(TODAY)
state['lastUpdated'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

with open(STATE_FILE, 'w') as f:
    json.dump(state, f, indent=2)

print()
print(f"✅ Decayed {decayed} item(s)")
if prune_candidates:
    print(f"⚠️  {len(prune_candidates)} item(s) below {PRUNE_THRESHOLD} (pruning candidates):")
    for iid, kind, strength in prune_candidates:
        print(f"   - {iid} ({kind}): {strength:.3f}")
    print("   Consider reviewing these for removal.")
PYTHON

echo ""
echo "Done. Backup saved to: $BACKUP"

# Log + resync
"$SKILL_DIR/log-event.sh" decay decayLastRun="$TODAY" >/dev/null 2>&1 || true
WORKSPACE="$WORKSPACE" "$SKILL_DIR/scripts/sync-state.sh" || true
