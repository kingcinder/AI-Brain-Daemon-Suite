#!/bin/bash
# test_dashboard_learning_signals.sh — The seven mechanism fields added in the
# neuroscience-mapping audit must surface in each skill's dashboard fragment
# and sync-state output, so the daemon's brain-dashboard shows the learning
# signals actually firing — not just the state files holding them.
#
# Fields asserted:
#   vta        → .data.recentRPE                  (TD reward-prediction error)
#   cerebellum → .data.skills[].predictionError   (forward-model PE)
#   insula     → .data.recentDiscrepancies        (interoceptive PE + composite)
#   social     → .data.recentSPE                  (social prediction error)
#   amygdala   → .data.salienceTags               (LeDoux/McGaugh salience)
#   hippocampus→ .data.corticalThemes             (CLS replay theme weights)
#   basal      → .data.gatedSelections            (no-go gate events)
#
# Plus: basal-ganglia action-select.sh actually PERSISTS gated-selection
# events into habit-state.json (the dashboard can only show what is stored).
#
# Run: bash tests/test_dashboard_learning_signals.sh
# Requires: jq, bc, python3

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
export OPENCLAW_WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory" "$TEST_WORKSPACE/memory/dashboard-fragments"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

check_frag() { # id jq_filter description
    local frag="$TEST_WORKSPACE/memory/dashboard-fragments/$1.json"
    if jq -e "$2" "$frag" >/dev/null 2>&1; then
        pass "$3"
    else
        fail "$3 — fragment data: $(jq -c '.data' "$frag" 2>/dev/null || echo unreadable)"
    fi
}

# ── 1. VTA — recentRPE ──────────────────────────────────────────────────
echo "Test 1: VTA recentRPE in fragment + VTA_STATE.md"
cat > "$TEST_WORKSPACE/memory/reward-state.json" << 'EOF'
{"drive": 0.62, "seeking": ["project_work"], "anticipating": [], "recentRewards": [],
 "recentRPE": [{"type": "accomplishment", "rpe": 0.4, "expectedBefore": 0.5, "expectedAfter": 0.62, "timestamp": "2026-08-23T00:00:00Z"}]}
EOF
bash "$ROOT/skills/vta-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag vta '.data.recentRPE | length >= 1 and .[0].rpe == 0.4' "VTA fragment carries recentRPE"
bash "$ROOT/skills/vta-memory/scripts/sync-motivation.sh" >/dev/null 2>&1 || true
if grep -q "Reward prediction errors" "$TEST_WORKSPACE/VTA_STATE.md"; then
    pass "VTA_STATE.md lists reward prediction errors"
else
    fail "VTA_STATE.md missing RPE section"
fi

# ── 2. Cerebellum — predictionError ─────────────────────────────────────
echo "Test 2: cerebellum predictionError in fragment + CEREBELLUM_STATE.md"
cat > "$TEST_WORKSPACE/memory/cerebellum-state.json" << 'EOF'
{"globalCalibration": 0.7,
 "skills": {"deploy": {"precision": 0.6, "smoothness": 0.5, "reps": 3, "predictionError": 0.25,
   "recentPredictions": [{"predicted": 0.5, "actual": 0.7, "error": 0.2, "timestamp": "2026-08-23T00:00:00Z"}]}}}
EOF
bash "$ROOT/skills/cerebellum-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag cerebellum '.data.skills | length >= 1 and .[0].predictionError == 0.25' "cerebellum fragment carries predictionError"
bash "$ROOT/skills/cerebellum-memory/scripts/sync-state.sh" >/dev/null 2>&1 || true
if grep -q "prediction error 0.250" "$TEST_WORKSPACE/CEREBELLUM_STATE.md"; then
    pass "CEREBELLUM_STATE.md lists prediction error"
else
    fail "CEREBELLUM_STATE.md missing prediction error"
fi

# ── 3. Insula — recentDiscrepancies ─────────────────────────────────────
echo "Test 3: insula recentDiscrepancies in fragment + INSULA_STATE.md"
cat > "$TEST_WORKSPACE/memory/interoceptive-state.json" << 'EOF'
{"channels": {"gutSignal": 0.3, "cognitiveLoad": 0.4},
 "recentSignals": [], "lastUpdated": "2026-08-23T00:00:00Z",
 "recentDiscrepancies": [{"channel": "gutSignal", "predicted": 0.1, "actual": 0.3, "error": 0.2, "timestamp": "2026-08-23T00:00:00Z"}],
 "composite": {"interoceptiveDiscrepancy": 0.2}}
EOF
bash "$ROOT/skills/insula-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag insula '(.data.recentDiscrepancies | length) >= 1 and (.data.interoceptiveDiscrepancy == 0.2)' "insula fragment carries recentDiscrepancies + composite"
bash "$ROOT/skills/insula-memory/scripts/sync-state.sh" >/dev/null 2>&1 || true
if grep -q "Interoceptive prediction errors" "$TEST_WORKSPACE/INSULA_STATE.md"; then
    pass "INSULA_STATE.md lists interoceptive prediction errors"
else
    fail "INSULA_STATE.md missing discrepancy section"
fi

# ── 4. Social — recentSPE ───────────────────────────────────────────────
echo "Test 4: social recentSPE in fragment + SOCIAL_STATE.md"
cat > "$TEST_WORKSPACE/memory/social-state.json" << 'EOF'
{"lastUpdated": "2026-08-23T00:00:00Z",
 "relationships": {"alice": {"name": "Alice", "type": "human", "trust": 0.6, "affinity": 0.5, "lastContact": "2026-08-23T00:00:00Z", "openLoops": []}},
 "recentSPE": [{"id": "alice", "expected": 0.5, "outcome": 1.1, "spe": 0.6, "timestamp": "2026-08-23T00:00:00Z"}]}
EOF
bash "$ROOT/skills/social-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag social '.data.recentSPE | length >= 1 and .[0].spe == 0.6' "social fragment carries recentSPE"
bash "$ROOT/skills/social-memory/scripts/sync-state.sh" >/dev/null 2>&1 || true
if grep -q "Social Prediction Errors" "$TEST_WORKSPACE/SOCIAL_STATE.md"; then
    pass "SOCIAL_STATE.md lists social prediction errors"
else
    fail "SOCIAL_STATE.md missing SPE section"
fi

# ── 5. Amygdala — salienceTags ──────────────────────────────────────────
echo "Test 5: amygdala salienceTags in fragment + AMYGDALA_STATE.md"
cat > "$TEST_WORKSPACE/memory/emotional-state.json" << 'EOF'
{"dimensions": {"valence": 0.2, "arousal": 0.8, "energy": 0.6},
 "lastUpdated": "2026-08-23T00:00:00Z",
 "recentEmotions": [],
 "salienceTags": [{"emotion": "fear", "salience": 0.7, "trigger": "edge case"}],
 "lastSalience": {"emotion": "fear", "salience": 0.7, "trigger": "edge case"}}
EOF
bash "$ROOT/skills/amygdala-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag amygdala '.data.lastSalience != null and .data.lastSalience.emotion == "fear"' "amygdala fragment carries salienceTags/lastSalience"
bash "$ROOT/skills/amygdala-memory/scripts/sync-state.sh" >/dev/null 2>&1 || true
if grep -q "Salience tags" "$TEST_WORKSPACE/AMYGDALA_STATE.md"; then
    pass "AMYGDALA_STATE.md lists salience tags"
else
    fail "AMYGDALA_STATE.md missing salience section"
fi

# ── 6. Hippocampus — cortical theme weights (memory/cortical.json) ──────
echo "Test 6: hippocampus cortical themes in fragment + HIPPOCAMPUS_CORE.md"
cat > "$TEST_WORKSPACE/memory/index.json" << 'EOF'
{"memories": [{"id": "m1", "content": "user prefers dark mode", "importance": 0.8, "domain": "user"}],
 "lastUpdated": "2026-08-23T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/cortical.json" << 'EOF'
{"version": 1,
 "themes": {"user/preferences": {"weight": 0.3, "traceCount": 3, "lastReplayed": "2026-08-23T00:00:00Z"}},
 "replays": []}
EOF
bash "$ROOT/skills/hippocampus-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag hippocampus '.data.corticalThemes | length >= 1 and .[0].weight == 0.3' "hippocampus fragment carries cortical theme weights"
bash "$ROOT/skills/hippocampus-memory/scripts/sync-core.sh" >/dev/null 2>&1 || true
if grep -q "Cortical Themes" "$TEST_WORKSPACE/HIPPOCAMPUS_CORE.md"; then
    pass "HIPPOCAMPUS_CORE.md lists cortical theme weights"
else
    fail "HIPPOCAMPUS_CORE.md missing cortical themes section"
fi

# ── 7. Basal ganglia — gated selections ─────────────────────────────────
echo "Test 7: basal-ganglia gated selections persisted + in fragment + BASAL_GANGLIA_STATE.md"

# 7a. action-select.sh must PERSIST a gated (no-go) event into habit-state.json
cat > "$TEST_WORKSPACE/memory/habit-state.json" << 'EOF'
{"habits": [], "suppressions": [], "procedures": [], "gatedSelections": []}
EOF
GATE_OUT=$(WORKSPACE="$TEST_WORKSPACE" bash "$ROOT/skills/basal-ganglia-memory/scripts/action-select.sh" \
    --options '[{"id":"a","label":"risky bet","score":0.3},{"id":"b","label":"safe move","score":0.8}]' \
    --threshold 0.9 --epsilon 0 2>/dev/null || true)
if echo "$GATE_OUT" | jq -e '.chosen == null' >/dev/null 2>&1; then
    pass "action-select gates the candidates (chosen: null)"
else
    fail "action-select did not gate: $GATE_OUT"
fi
if jq -e '.gatedSelections | length >= 1 and .[0].best == 0.8 and .[0].threshold == 0.9' \
    "$TEST_WORKSPACE/memory/habit-state.json" >/dev/null 2>&1; then
    pass "gated selection persisted to habit-state.json (.gatedSelections)"
else
    fail "gated selection NOT persisted: $(jq -c '.gatedSelections' "$TEST_WORKSPACE/memory/habit-state.json" 2>/dev/null || echo unreadable)"
fi

# 7b. fragment + markdown carry it
bash "$ROOT/skills/basal-ganglia-memory/scripts/generate-dashboard.sh" >/dev/null 2>&1 || true
check_frag basal '.data.gatedSelections | length >= 1 and .[0].best == 0.8' "basal fragment carries gatedSelections"
bash "$ROOT/skills/basal-ganglia-memory/scripts/sync-state.sh" >/dev/null 2>&1 || true
if grep -q "Gated Selections" "$TEST_WORKSPACE/BASAL_GANGLIA_STATE.md"; then
    pass "BASAL_GANGLIA_STATE.md lists gated selections"
else
    fail "BASAL_GANGLIA_STATE.md missing gated selections section"
fi

# ── 8. Builder still assembles a page containing all seven tabs ──────────
echo "Test 8: dashboard-builder assembles the page with all seven fragments"

bash "$ROOT/skills/cerebellum-memory/scripts/dashboard-builder.sh" >/dev/null 2>&1 || true
TABS=$(grep -o 'data-tab="[a-z_]*"' "$TEST_WORKSPACE/brain-dashboard.html" 2>/dev/null | sort -u | tr '\n' ' ')
MISSING=0
for want in vta cerebellum insula social amygdala hippocampus basal; do
    if ! grep -q "data-tab=\"$want\"" "$TEST_WORKSPACE/brain-dashboard.html" 2>/dev/null; then
        fail "dashboard page missing $want tab"
        MISSING=1
    fi
done
[ "$MISSING" = "0" ] && pass "all seven learning-signal tabs present in assembled page"

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Dashboard Learning Signal Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
