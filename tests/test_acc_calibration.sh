#!/bin/bash
# Unit: acc-calibration.sh joins anterior-cingulate conflict flags with
# acc-error corrections by firstSeen timestamps, computing the flag→error
# hit rate, per-type breakdown, and unpredicted-error count. Missing/corrupt
# sources degrade to zeros — never abort.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory"

CAL="$ROOT/core/self-mod/acc-calibration.sh"
[ -x "$CAL" ] || { echo "FAIL: acc-calibration.sh not executable"; exit 1; }

# ── Empty workspace → valid JSON, zeroed fields ──────────────────────────────
OUT=$(WORKSPACE="$WORKSPACE" bash "$CAL")
echo "$OUT" | jq -e '.total_conflicts == 0 and .flags_followed_by_error == 0 and .hit_rate == 0.0 and .false_positive_rate == 0.0 and .total_errors == 0 and .by_type == {}' >/dev/null \
  || { echo "FAIL: empty-workspace shape: $OUT"; exit 1; }

# ── Seed: 2 conflicts (uncertainty 08-01, factual 08-02); 1 error 08-03 ─────
# Window 7d: uncertainty→error = hit; factual→error (2d later) = hit.
cat > "$WORKSPACE/memory/conflict-state.json" << 'EOF'
{
  "conflictLoad": 0.4,
  "activeConflicts": {
    "uncertainty_1": {"type": "uncertainty", "firstSeen": "2026-08-01T00:00:00Z", "severity": "moderate"},
    "factual_1": {"type": "factual", "firstSeen": "2026-08-02T00:00:00Z", "severity": "high"}
  },
  "resolvedConflicts": [],
  "stats": {"totalConflictsLogged": 2, "totalResolved": 0}
}
EOF
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{
  "activePatterns": {
    "wrong-config": {"count": 2, "firstSeen": "2026-08-03T00:00:00Z", "severity": "warning"}
  },
  "resolved": {}
}
EOF
OUT2=$(WORKSPACE="$WORKSPACE" bash "$CAL")
echo "$OUT2" | jq -e '.total_conflicts == 2 and .flags_followed_by_error == 2 and .hit_rate == 1.0 and .total_errors == 1 and .errors_unpredicted == 0' >/dev/null \
  || { echo "FAIL: temporal join both hits: $OUT2"; exit 1; }
echo "$OUT2" | jq -e '.by_type.uncertainty.hits == 1 and .by_type.factual.hits == 1' >/dev/null \
  || { echo "FAIL: per-type breakdown: $OUT2"; exit 1; }

# ── Window miss: error far outside the window → hit_rate drops ──────────────
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{
  "activePatterns": {
    "late-error": {"count": 1, "firstSeen": "2026-08-20T00:00:00Z"}
  },
  "resolved": {}
}
EOF
OUT3=$(WORKSPACE="$WORKSPACE" bash "$CAL")
echo "$OUT3" | jq -e '.total_conflicts == 2 and .flags_followed_by_error == 0 and .hit_rate == 0.0 and .errors_unpredicted == 1' >/dev/null \
  || { echo "FAIL: window miss: $OUT3"; exit 1; }

# ── Window override: --window-days 20 catches the late error ────────────────
OUT4=$(WORKSPACE="$WORKSPACE" bash "$CAL" --window-days 20)
echo "$OUT4" | jq -e '.window_days == 20 and .flags_followed_by_error == 2 and .hit_rate == 1.0' >/dev/null \
  || { echo "FAIL: window override: $OUT4"; exit 1; }

# ── Resolved conflicts count too (they keep firstSeen/type) ─────────────────
cat > "$WORKSPACE/memory/conflict-state.json" << 'EOF'
{
  "conflictLoad": 0.0,
  "activeConflicts": {},
  "resolvedConflicts": [
    {"id": "intent_1", "type": "intent", "firstSeen": "2026-08-04T00:00:00Z", "resolvedAt": "2026-08-05T00:00:00Z"}
  ],
  "stats": {"totalConflictsLogged": 3, "totalResolved": 1}
}
EOF
cat > "$WORKSPACE/memory/acc-state.json" << 'EOF'
{
  "activePatterns": {
    "wrong-config": {"count": 1, "firstSeen": "2026-08-05T00:00:00Z"}
  },
  "resolved": {}
}
EOF
OUT5=$(WORKSPACE="$WORKSPACE" bash "$CAL")
echo "$OUT5" | jq -e '.total_conflicts == 1 and .flags_followed_by_error == 1 and .by_type.intent.hits == 1' >/dev/null \
  || { echo "FAIL: resolved-conflict join: $OUT5"; exit 1; }

# ── Corrupt sources degrade, not abort ──────────────────────────────────────
echo 'not-json{{' > "$WORKSPACE/memory/conflict-state.json"
OUT6=$(WORKSPACE="$WORKSPACE" bash "$CAL")
echo "$OUT6" | jq -e '.total_conflicts == 0 and .hit_rate == 0.0' >/dev/null \
  || { echo "FAIL: corrupt-source degradation: $OUT6"; exit 1; }

echo "PASS: acc-calibration"
