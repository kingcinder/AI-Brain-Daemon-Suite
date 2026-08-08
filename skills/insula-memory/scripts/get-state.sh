#!/usr/bin/env bash
# get-state.sh — Print current interoceptive state
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
[ ! -f "$STATE_FILE" ] && echo "No state file. Run: ./install.sh" && exit 1
python3 - "$STATE_FILE" << 'PYTHON'
import json, sys
s = json.load(open(sys.argv[1]))
c = s.get('channels', {})
print("🌡️  Interoceptive State")
print(f"   gutSignal:         {c.get('gutSignal', 0):+.2f}")
print(f"   cognitiveLoad:     {c.get('cognitiveLoad', 0.3):.2f}")
print(f"   friction:          {c.get('friction', 0.1):.2f}")
print(f"   somaticComfort:    {c.get('somaticComfort', 0.3):+.2f}")
print(f"   empathicResonance: {c.get('empathicResonance', 0.4):.2f}")
print(f"   selfCoherence:     {c.get('selfCoherence', 0.7):.2f}")
print(f"   contextSaturation: {c.get('contextSaturation', 0.2):.2f}")
recent = s.get('recentSignals', [])[-3:]
if recent:
    print("\n   Recent signals:")
    for sig in reversed(recent):
        print(f"     {sig.get('label','?')} ({sig.get('intensity',0):.1f}) — {sig.get('source','')[:60]}")
PYTHON
