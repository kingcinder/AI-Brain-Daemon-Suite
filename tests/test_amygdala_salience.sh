#!/bin/bash
# Unit: Amygdala update-state tags high-salience events (LeDoux dual-pathway
# threat tag; McGaugh's amygdala-mediated memory enhancement) — salience =
# intensity × (0.5 + 0.5·arousal), tagged when ≥ 0.6.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/emotional-state.json" << 'EOF'
{"dimensions":{"arousal":0.8,"valence":0.5},"recentEmotions":[]}
EOF

# NOTE: the seed intentionally OMITS salienceTags/lastSalience — the shape
# of pre-audit production state files. The script must handle the missing
# keys (null-safe // []), so this test is the regression lock for the
# reviewer-flagged jq null+array bug.

# High-intensity fear under high arousal: salience 0.9·(0.5+0.4) = 0.81 ≥ 0.6
# → tagged with emotion + salience + trigger.
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/amygdala-memory/scripts/update-state.sh" --emotion fear --intensity 0.9 --trigger "loud noise" >/dev/null 2>&1
jq -e '.salienceTags | length == 1' "$WORKSPACE/memory/emotional-state.json" >/dev/null
jq -e '.salienceTags[0].emotion == "fear"' "$WORKSPACE/memory/emotional-state.json" >/dev/null
jq -e '.salienceTags[0].salience >= 0.6' "$WORKSPACE/memory/emotional-state.json" >/dev/null
jq -e '.lastSalience != null' "$WORKSPACE/memory/emotional-state.json" >/dev/null

# Low-intensity calm: salience ≈ 0.3·(0.5+0.5·0.95) ≈ 0.29 < 0.6 → no tag.
# (the fear cascade above raised arousal, making this an even harder case)
WORKSPACE="$WORKSPACE" bash "$ROOT/skills/amygdala-memory/scripts/update-state.sh" --emotion calm --intensity 0.3 >/dev/null 2>&1
jq -e '.salienceTags | length == 1' "$WORKSPACE/memory/emotional-state.json" >/dev/null
jq -e '.recentEmotions | length == 2' "$WORKSPACE/memory/emotional-state.json" >/dev/null

echo "PASS: amygdala salience tagging"
