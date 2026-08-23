#!/bin/bash
# test_learning_signal_routes.sh — Verify the three new cross-region
# learning-signal routes are wired end-to-end:
#
#   Arc A (VTA → ACC):  log-reward.sh publishes rpe_logged on a notable
#                       prediction error; route-signals.sh carries it to
#                       anterior-cingulate-memory flag-attention.sh.
#   Arc B (amygdala → hippocampus): update-state.sh publishes salience_tag
#                       when a high-salience tag fires; route-signals.sh
#                       carries it to hippocampus note-salience.sh; the
#                       encode-pipeline salience boost reads the hint.
#   Arc C (insula → PFC): update-state.sh publishes
#                       interoceptive_discrepancy on a notable composite;
#                       route-signals.sh carries it to PFC
#                       note-uncertainty.sh; decide.sh dampens scores.
#
# Each arc asserts the ROUTE exists, the PRODUCER publishes, and the
# CONSUMER records a state change (not just "script ran without error").
#
# Run: bash tests/test_learning_signal_routes.sh
# Requires: jq, awk, bc (existing Suite dependency set)

set -euo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
# Export BOTH workspace vars: insula's update-state.sh prefers
# OPENCLAW_WORKSPACE, everything else prefers WORKSPACE. Exporting both once
# guarantees the test is fully self-contained and can never touch the live
# ~/.hermes/workspace.
export WORKSPACE="$WS"
export OPENCLAW_WORKSPACE="$WS"
mkdir -p "$WS/memory"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

ROUTES="$ROOT/core/signaling/route-signals.sh"
VTA_LOG="$ROOT/skills/vta-memory/scripts/log-reward.sh"
AMY_UPDATE="$ROOT/skills/amygdala-memory/scripts/update-state.sh"
INS_UPDATE="$ROOT/skills/insula-memory/scripts/update-state.sh"
ACC_FLAG="$ROOT/skills/anterior-cingulate-memory/scripts/flag-attention.sh"
HIP_NOTE="$ROOT/skills/hippocampus-memory/scripts/note-salience.sh"
PFC_NOTE="$ROOT/skills/prefrontal-cortex-memory/scripts/note-uncertainty.sh"
PFC_DECIDE="$ROOT/skills/prefrontal-cortex-memory/scripts/decide.sh"
BUS="$WS/memory/brain-signals.jsonl"

# ── Seed minimal state files (production-shaped, real scripts) ────────────
cat > "$WS/memory/reward-state.json" << 'EOF'
{"drive": 0.5, "seeking": [], "anticipating": [], "recentRewards": [],
 "rewardHistory": {"totalRewards": 0, "byType": {}}, "expectedReward": {}}
EOF
cat > "$WS/memory/emotional-state.json" << 'EOF'
{"dimensions": {"valence": 0.0, "arousal": 0.5, "energy": 0.5},
 "recentEmotions": [], "salienceTags": [], "lastSalience": null,
 "lastUpdated": "2026-08-23T00:00:00Z"}
EOF
cat > "$WS/memory/interoceptive-state.json" << 'EOF'
{"channels": {"gutSignal": 0.1, "cognitiveLoad": 0.3, "friction": 0.1,
  "somaticComfort": 0.3, "empathicResonance": 0.4, "selfCoherence": 0.7,
  "contextSaturation": 0.2}, "predictedChannels": {}, "recentSignals": [],
 "recentDiscrepancies": [], "composite": {}, "stats": {},
 "lastUpdated": "2026-08-23T00:00:00Z"}
EOF
cat > "$WS/memory/conflict-state.json" << 'EOF'
{"conflictLoad": 0.3, "attentionFlags": [], "activeConflicts": {},
 "stats": {"totalConflictsLogged": 0, "totalAttentionFlags": 0},
 "lastUpdated": "2026-08-23T00:00:00Z"}
EOF

# ── Arc A: VTA RPE → ACC flag-attention ──────────────────────────────────
echo "Test 1: routing table carries the three learning-signal arcs"
if grep -q 'vta-memory|rpe_logged|anterior-cingulate-memory' "$ROUTES"; then
    pass "route: vta-memory rpe_logged → anterior-cingulate-memory flag-attention.sh"
else
    fail "missing route: vta-memory rpe_logged → ACC"
fi
if grep -q 'amygdala-memory|salience_tag|hippocampus-memory' "$ROUTES"; then
    pass "route: amygdala-memory salience_tag → hippocampus note-salience.sh"
else
    fail "missing route: amygdala-memory salience_tag → hippocampus"
fi
if grep -q 'insula-memory|interoceptive_discrepancy|prefrontal-cortex-memory' "$ROUTES"; then
    pass "route: insula-memory interoceptive_discrepancy → PFC note-uncertainty.sh"
else
    fail "missing route: insula-memory interoceptive_discrepancy → PFC"
fi

echo "Test 2: VTA publishes rpe_logged on a notable prediction error"
# Intensity 0.9 vs expected 0.5 → RPE 0.4 (≥ 0.15 threshold) → must publish.
bash "$VTA_LOG" --type accomplishment --source "test route arc A" --intensity 0.9 >/dev/null 2>&1
if grep -q '"source":"vta-memory"' "$BUS" 2>/dev/null && grep -q '"signal":"rpe_logged"' "$BUS" 2>/dev/null; then
    pass "rpe_logged published to the signal bus"
else
    fail "rpe_logged NOT published (bus: $(cat "$BUS" 2>/dev/null || echo 'empty'))"
fi
# Sub-threshold reward (intensity 0.5, expected now ~0.62 → RPE ~ -0.12 < 0.15)
# must NOT spam the bus — count stays at 1 rpe_logged entry.
PRE=$(grep -c 'rpe_logged' "$BUS" 2>/dev/null || echo 0)
bash "$VTA_LOG" --type accomplishment --source "test route arc A sub" --intensity 0.5 >/dev/null 2>&1
POST=$(grep -c 'rpe_logged' "$BUS" 2>/dev/null || echo 0)
if [ "$POST" -eq "$PRE" ]; then
    pass "sub-threshold reward does not re-publish rpe_logged ($PRE → $POST)"
else
    fail "sub-threshold reward published rpe_logged ($PRE → $POST)"
fi

echo "Test 3: ACC consumer accepts the rpe flag directive"
if bash "$ACC_FLAG" --add "rpe_accomplishment" --reason "reward prediction error" >/dev/null 2>&1 \
   && jq -e '.attentionFlags[] | select(.topic == "rpe_accomplishment")' "$WS/memory/conflict-state.json" >/dev/null 2>&1; then
    pass "flag-attention.sh records the rpe flag (provenance: reward prediction error)"
else
    fail "ACC flag-attention.sh did not record the rpe flag"
fi

# ── Arc B: amygdala salience → hippocampus encoding weight ───────────────
echo "Test 4: amygdala publishes salience_tag when a high-salience tag fires"
# fear + intensity 0.9 + arousal 0.5 → salience = 0.9 × (0.5 + 0.5×0.5) = 0.675 ≥ 0.6 → tag fires.
bash "$AMY_UPDATE" --emotion fear --intensity 0.9 --trigger "test route arc B" >/dev/null 2>&1
if grep -q '"source":"amygdala-memory"' "$BUS" 2>/dev/null && grep -q '"signal":"salience_tag"' "$BUS" 2>/dev/null; then
    pass "salience_tag published to the signal bus"
else
    fail "salience_tag NOT published (bus: $(cat "$BUS" 2>/dev/null | tail -2))"
fi

echo "Test 5: hippocampus consumer records the salience hint"
if bash "$HIP_NOTE" --emotion fear --salience 0.675 >/dev/null 2>&1 \
   && jq -e '.hints[0].emotion == "fear" and .hints[0].salience == 0.675' "$WS/memory/salience-hints.json" >/dev/null 2>&1; then
    pass "note-salience.sh records the hint (emotion=fear, salience=0.675)"
else
    fail "note-salience.sh did not record the hint"
fi

echo "Test 6: encode-pipeline salience boost reads the hint"
if grep -q 'salience-hints.json' "$ROOT/skills/hippocampus-memory/scripts/encode-pipeline.sh" && \
   grep -q 'salience_hint_strength' "$ROOT/skills/hippocampus-memory/scripts/encode-pipeline.sh"; then
    pass "encode-pipeline.sh reads salience-hints.json and applies salience_hint_strength boost"
else
    fail "encode-pipeline.sh missing salience boost logic"
fi

# ── Arc C: insula discrepancy → PFC confidence dampening ─────────────────
echo "Test 7: insula publishes interoceptive_discrepancy on a notable composite"
# discord at 0.6 slams gutSignal −0.4×0.6 = −0.24 vs prior 0.1 → error 0.34
# (≥ 0.15 threshold) → composite ≥ 0.34 → must publish.
bash "$INS_UPDATE" --signal discord --intensity 0.6 >/dev/null 2>&1
if grep -q '"source":"insula-memory"' "$BUS" 2>/dev/null && grep -q '"signal":"interoceptive_discrepancy"' "$BUS" 2>/dev/null; then
    pass "interoceptive_discrepancy published to the signal bus"
else
    fail "interoceptive_discrepancy NOT published (bus: $(cat "$BUS" 2>/dev/null | tail -2))"
fi

echo "Test 8: PFC consumer records the uncertainty input"
if bash "$PFC_NOTE" --value 0.34 >/dev/null 2>&1 \
   && jq -e '.interoceptiveDiscrepancy == 0.34' "$WS/memory/pfc-uncertainty.json" >/dev/null 2>&1; then
    pass "note-uncertainty.sh records interoceptiveDiscrepancy=0.34"
else
    fail "note-uncertainty.sh did not record the uncertainty input"
fi

echo "Test 9: decide.sh dampens option scores under high discrepancy"
cat > "$WS/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}],
 "inhibitions": [], "decisionLog": []}
EOF
cat > "$WS/memory/executive-load.json" << 'EOF'
{"E": 0.4, "band": "desired"}
EOF
OPTIONS='[{"id":"project_work","label":"work on the brain suite","weight":1.0},{"id":"idle","label":"idle","weight":0.2}]'
# Baseline: remove the uncertainty file written by Test 8 (0.34 would already
# damp at > 0.3) so this is a TRUE no-signal baseline, not a doubly-damped one.
rm -f "$WS/memory/pfc-uncertainty.json"
BASE_OUT=$(WORKSPACE="$WS" PFC_SEMANTIC_MATCHING=off bash "$PFC_DECIDE" --context "test arc C" --options "$OPTIONS" 2>/dev/null || echo '{}')
# With uncertainty: write the file, then re-run — project_work must score lower.
bash "$PFC_NOTE" --value 0.8 >/dev/null 2>&1
DAMP_OUT=$(WORKSPACE="$WS" PFC_SEMANTIC_MATCHING=off bash "$PFC_DECIDE" --context "test arc C" --options "$OPTIONS" 2>/dev/null || echo '{}')
BASE_PW=$(echo "$BASE_OUT" | jq -r '.scores.project_work // 0')
DAMP_PW=$(echo "$DAMP_OUT" | jq -r '.scores.project_work // 0')
if awk -v b="$BASE_PW" -v d="$DAMP_PW" 'BEGIN { exit !(d < b) }'; then
    pass "project_work damped by interoceptive discrepancy ($BASE_PW → $DAMP_PW)"
else
    fail "no dampening: project_work $BASE_PW → $DAMP_PW (disc=0.8 should lower confidence)"
fi

echo ""
echo "────────────────────────────────────────────"
echo "Learning-Signal Route Tests: $PASS passed, $FAIL failed"
echo "────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
