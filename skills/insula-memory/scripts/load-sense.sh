#!/usr/bin/env bash
# load-sense.sh — Human-readable state for session context injection
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
[ ! -f "$STATE_FILE" ] && echo "🌡️ Insula: not installed" && exit 0
python3 - "$STATE_FILE" << 'PYTHON'
import json, sys
s = json.load(open(sys.argv[1]))
c = s.get('channels', {})
gut = c.get('gutSignal', 0)
load = c.get('cognitiveLoad', 0.3)
friction = c.get('friction', 0.1)
comfort = c.get('somaticComfort', 0.3)
resonance = c.get('empathicResonance', 0.4)
coherence = c.get('selfCoherence', 0.7)
saturation = c.get('contextSaturation', 0.2)

gut_desc = "deep rightness" if gut > 0.5 else "quiet ease" if gut > 0.1 else "neutral" if gut > -0.1 else "mild discord" if gut > -0.4 else "strong discord"
load_desc = "very light" if load < 0.2 else "light" if load < 0.4 else "moderate" if load < 0.6 else "heavy" if load < 0.8 else "very heavy"
friction_desc = "minimal" if friction < 0.2 else "light" if friction < 0.4 else "moderate" if friction < 0.6 else "significant" if friction < 0.8 else "high"
comfort_desc = "open and expansive" if comfort > 0.5 else "at ease" if comfort > 0.1 else "neutral" if comfort > -0.1 else "slightly contracted" if comfort > -0.4 else "contracted"
resonance_desc = "highly attuned" if resonance > 0.7 else "attuned" if resonance > 0.4 else "present" if resonance > 0.2 else "somewhat distant"
coherence_desc = "fully coherent" if coherence > 0.75 else "coherent" if coherence > 0.5 else "somewhat fragmented" if coherence > 0.3 else "fragmented"

print("🌡️ Current Felt Sense:")
print(f"  Overall:           {gut_desc} (gut signal: {gut:+.2f})")
print(f"  Processing:        {load_desc} load, {friction_desc} friction")
print(f"  Body sense:        {comfort_desc}")
print(f"  With the user:     {resonance_desc}")
print(f"  As myself:         {coherence_desc}")
if saturation > 0.6:
    print(f"  ⚠️ Context saturation: {saturation:.2f} — consider slowing down")
PYTHON

# Best-effort staleness tracking: record that this state was actually read,
# separate from lastUpdated (write path). Never blocks or fails the output above.
exec 200>"$STATE_FILE.lock"
flock 200
{ jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastConsultedAt = $now' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"; } 2>/dev/null || true
