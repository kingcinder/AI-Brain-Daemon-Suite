#!/usr/bin/env bash
# load-habits.sh — Human-readable basal-ganglia state for session context injection.
# The organ's reader: prints the habit summary and stamps lastConsultedAt on
# habit-state.json (the read watermark the dashboard freshness panel shows).
# Built 2026-11-13 under Dither's full-integration order — basal-ganglia was
# the one organ with no reader at all. Mirrors the sibling load-* pattern.
set -euo pipefail
WORKSPACE="${WORKSPACE:-${BRAIN_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.juno-brain/workspace}}}"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
[ ! -f "$STATE_FILE" ] && echo "🎯 Basal Ganglia: not installed" && exit 0
python3 - "$STATE_FILE" << 'PYTHON'
import json, sys
s = json.load(open(sys.argv[1]))
habits = s.get('habits', [])
active = [h for h in habits if h.get('status', 'active') == 'active']
active.sort(key=lambda h: h.get('strength', 0), reverse=True)
print("🎯 Basal Ganglia — Habits:")
print(f"  {len(active)} active / {len(habits)} total · updated {s.get('lastUpdated', '?')}")
for h in active[:5]:
    print(f"  [{h.get('strength', 0):.2f} · {h.get('executions', 0)}x] {h.get('cue', '?')}")
    print(f"        → {h.get('routine', '?')}")
PYTHON

# Best-effort staleness tracking: record that this state was actually read,
# separate from lastUpdated (write path). Never blocks or fails the output above.
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
