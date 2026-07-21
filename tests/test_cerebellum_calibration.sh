#!/bin/bash
# Skill-specific test: cerebellum-memory get-calibration must read/update
# cerebellum-state.json skill precision — would fail if get-calibration.sh ignored state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/skills/cerebellum-memory/scripts/get-calibration.sh"
export WORKSPACE
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/cerebellum-state.json" << 'EOF'
{
  "globalCalibration": 0.55,
  "skills": {
    "demo-skill": {
      "precision": 0.81,
      "smoothness": 0.66,
      "reps": 12,
      "recentCorrections": [{"note": "slow-start"}]
    }
  },
  "lastConsultedAt": ""
}
EOF
chmod +x "$SCRIPT"
OUT=$(WORKSPACE="$WORKSPACE" bash "$SCRIPT" --skill demo-skill --json)
echo "$OUT" | jq -e '.precision == 0.81 and .smoothness == 0.66 and .reps == 12' >/dev/null
# Human path must mention precision
OUT2=$(WORKSPACE="$WORKSPACE" bash "$SCRIPT" --skill demo-skill)
echo "$OUT2" | grep -q 'precision=0.81'
echo "PASS: cerebellum get-calibration skill-specific"
