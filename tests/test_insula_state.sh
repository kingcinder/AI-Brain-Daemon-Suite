#!/bin/bash
# Skill-specific test: insula-memory get-state must surface interoceptive channels
# from interoceptive-state.json — fails if get-state.sh reads the wrong file/keys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/skills/insula-memory/scripts/get-state.sh"
export WORKSPACE OPENCLAW_WORKSPACE
WORKSPACE=$(mktemp -d)
OPENCLAW_WORKSPACE="$WORKSPACE"
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/interoceptive-state.json" << 'EOF'
{
  "channels": {
    "gutSignal": 0.42,
    "cognitiveLoad": 0.77,
    "friction": 0.11,
    "somaticComfort": 0.22,
    "empathicResonance": 0.33,
    "selfCoherence": 0.88,
    "contextSaturation": 0.19
  },
  "recentSignals": [{"label": "test-signal", "intensity": 0.9, "source": "unit-test"}]
}
EOF
chmod +x "$SCRIPT"
OUT=$(WORKSPACE="$WORKSPACE" OPENCLAW_WORKSPACE="$WORKSPACE" bash "$SCRIPT")
echo "$OUT" | grep -q 'gutSignal'
echo "$OUT" | grep -q '0.42\|+.42\|+0.42'
echo "$OUT" | grep -q 'cognitiveLoad'
echo "$OUT" | grep -q '0.77'
echo "$OUT" | grep -q 'test-signal'
echo "PASS: insula get-state skill-specific"
