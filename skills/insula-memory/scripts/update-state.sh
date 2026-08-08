#!/usr/bin/env bash
# update-state.sh — Log a gut signal or set a channel directly
# Usage:
#   ./scripts/update-state.sh --signal <name> [--intensity <0.0-1.0>] [--source <text>]
#   ./scripts/update-state.sh --channel <name> --set <value>
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ ! -f "$STATE_FILE" ] && echo "No state file. Run: ./install.sh" && exit 1

SIGNAL=""; INTENSITY="0.6"; SOURCE=""; CHANNEL=""; SET_VAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --signal)   SIGNAL="$2"; shift 2 ;;
    --intensity) INTENSITY="$2"; shift 2 ;;
    --source)   SOURCE="$2"; shift 2 ;;
    --channel)  CHANNEL="$2"; shift 2 ;;
    --set)      SET_VAL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Signal → channel delta map
python3 - "$STATE_FILE" "$SIGNAL" "$INTENSITY" "$SOURCE" "$CHANNEL" "$SET_VAL" << 'PYTHON'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
signal = sys.argv[2]
intensity = float(sys.argv[3]) if sys.argv[3] else 0.6
source = sys.argv[4]
channel = sys.argv[5]
set_val = sys.argv[6]

with open(state_path) as f:
    state = json.load(f)

c = state.setdefault('channels', {})
defaults = {'gutSignal':0.1,'cognitiveLoad':0.3,'friction':0.1,'somaticComfort':0.3,
            'empathicResonance':0.4,'selfCoherence':0.7,'contextSaturation':0.2}
for k, v in defaults.items():
    c.setdefault(k, v)

# Direct channel set
if channel and set_val != '':
    old = c.get(channel, 0)
    c[channel] = float(set_val)
    print(f"✅ {channel}: {old:.2f} → {float(set_val):.2f}")
    state['lastUpdated'] = datetime.now(timezone.utc).isoformat()
    with open(state_path, 'w') as f:
        json.dump(state, f, indent=2)
    sys.exit(0)

# Signal → delta map (normalized to intensity)
signal_map = {
    'congruence':    {'gutSignal':+.4, 'selfCoherence':+.2, 'somaticComfort':+.2},
    'discord':       {'gutSignal':-.4, 'friction':+.3, 'somaticComfort':-.2},
    'ease':          {'gutSignal':+.3, 'cognitiveLoad':-.2, 'friction':-.2, 'somaticComfort':+.2},
    'overwhelm':     {'gutSignal':-.3, 'cognitiveLoad':+.4, 'contextSaturation':+.3, 'somaticComfort':-.2},
    'resistance':    {'gutSignal':-.3, 'friction':+.4, 'selfCoherence':-.2},
    'resonance':     {'gutSignal':+.3, 'empathicResonance':+.4, 'somaticComfort':+.2},
    'depletion':     {'gutSignal':-.2, 'cognitiveLoad':+.2, 'somaticComfort':-.3, 'contextSaturation':+.2},
    'expansion':     {'gutSignal':+.4, 'selfCoherence':+.2, 'somaticComfort':+.3, 'friction':-.2},
    'vigilance':     {'cognitiveLoad':+.2, 'gutSignal':-.1, 'empathicResonance':+.2},
    'stillness':     {'gutSignal':+.3, 'cognitiveLoad':-.2, 'friction':-.2, 'somaticComfort':+.2},
    'strain':        {'cognitiveLoad':+.3, 'friction':+.2, 'somaticComfort':-.2},
    'flow':          {'gutSignal':+.3, 'cognitiveLoad':-.3, 'friction':-.3, 'selfCoherence':+.2},
    'disconnection': {'empathicResonance':-.3, 'gutSignal':-.2, 'somaticComfort':-.2},
    'fragmentation': {'selfCoherence':-.4, 'friction':+.2, 'gutSignal':-.2},
    'saturation':    {'contextSaturation':+.4, 'cognitiveLoad':+.2, 'gutSignal':-.2},
}

if not signal:
    print("No signal specified. Use --signal <name> or --channel <name> --set <value>")
    sys.exit(1)

deltas = signal_map.get(signal)
if not deltas:
    print(f"Unknown signal: {signal}. Known: {', '.join(signal_map.keys())}")
    sys.exit(1)

limits = {'gutSignal':(-1,1),'somaticComfort':(-1,1)}
default_limits = (0, 1)

print(f"🌡️ Logged signal: {signal} (intensity: {intensity:.1f})")
for ch, raw_delta in deltas.items():
    delta = raw_delta * intensity
    old = c.get(ch, defaults.get(ch, 0))
    mn, mx = limits.get(ch, default_limits)
    new = max(mn, min(mx, old + delta))
    c[ch] = round(new, 3)
    print(f"   {ch}: {old:+.3f} → {new:+.3f} (Δ{delta:+.3f})")

recent = state.setdefault('recentSignals', [])
recent.append({'label': signal, 'intensity': intensity, 'source': source,
               'timestamp': datetime.now(timezone.utc).isoformat()})
state['recentSignals'] = recent[-20:]
state.setdefault('stats', {})['totalSignalsLogged'] = state['stats'].get('totalSignalsLogged', 0) + 1
state['lastUpdated'] = datetime.now(timezone.utc).isoformat()

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2)
PYTHON

"$SCRIPT_DIR/sync-state.sh" > /dev/null 2>&1 || true
