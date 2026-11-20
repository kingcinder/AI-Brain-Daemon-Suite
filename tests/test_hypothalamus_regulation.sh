#!/bin/bash
# test_hypothalamus_regulation.sh — unit tests for the hypothalamus
# organ (homeostatic regulation), created 2026-11-20 under Phase G
# (Amendment 4) of the Gated-Ingress Refactor. Fixture variables:
# queue_depth and pending_total out of bounds, the rest in bounds.
# Asserts: exactly the out-of-bounds drives are issued + ledgered,
# in-bounds variables stay silent, state records the pass, and the
# reader stamps lastConsultedAt.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
FAILS=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

mkdir -p "$FIX/core/gate" "$FIX/memory"
cp "$ROOT/core/gate/store_write.py" "$ROOT/core/gate/"
cp "$ROOT/core/gate/envelope.py" "$FIX/core/gate/"
cp "$ROOT/core/gate/flows.json" "$FIX/core/gate/" 2>/dev/null || echo '{"flows": [], "internal_stores": []}' > "$FIX/core/gate/flows.json"
cat > "$FIX/vars.json" <<'EOF'
{"queue_depth": 25, "deadletter_count": 0, "pending_total": 1400,
 "vm_disk_free_pct": 55.0, "insula_cognitive_load": 0.3,
 "insula_context_saturation": 0.2}
EOF
echo '{"version": "1.0", "lastConsultedAt": null, "totals": {"passes": 0, "drivesIssued": 0}}' > "$FIX/memory/hypothalamus-state.json"

OUT="$(WORKSPACE="$FIX" BRAIN_WORKSPACE="$FIX" OPENCLAW_WORKSPACE="$FIX" HYPOTHALAMUS_VARS_JSON="$FIX/vars.json" python3 "$ROOT/skills/hypothalamus-memory/scripts/regulate.py" 2>&1)"
echo "$OUT"
echo "$OUT" | grep -q "2 corrective drive" && ok "two drives issued" || bad "drive count wrong"
LEDGER="$FIX/memory/homeostasis-ledger.jsonl"
grep -q '"variable": "queue_depth"' "$LEDGER" && ok "queue_depth drive ledgered" || bad "queue_depth drive missing"
grep -q '"variable": "pending_total"' "$LEDGER" && ok "pending_total drive ledgered" || bad "pending_total drive missing"
grep -q '"variable": "vm_disk_free_pct"' "$LEDGER" && bad "in-bounds variable drove" || ok "in-bounds variables silent"
TOTALS="$(python3 -c "import json; t=json.load(open('$FIX/memory/hypothalamus-state.json'))['totals']; print(t['passes'], t['drivesIssued'])")"
[ "$TOTALS" = "1 2" ] && ok "state totals (1 pass, 2 drives)" || bad "state totals: $TOTALS"
grep -q "homeostasis.drive" "$FIX/memory/brain-signals.jsonl" && ok "drive envelopes entered the signal bus" || bad "no drive envelopes on the bus"

WORKSPACE="$FIX" bash "$ROOT/skills/hypothalamus-memory/scripts/sync-state.sh" >/dev/null 2>&1
WORKSPACE="$FIX" bash "$ROOT/skills/hypothalamus-memory/scripts/read-state.sh" >/dev/null 2>&1
STAMP="$(python3 -c "import json; print(json.load(open('$FIX/memory/hypothalamus-state.json')).get('lastConsultedAt'))")"
[ "$STAMP" != "None" ] && [ -n "$STAMP" ] && ok "reader stamps lastConsultedAt" || bad "reader stamp missing"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "hypothalamus: ALL PASS"; exit 0; else echo "hypothalamus: $FAILS FAILURES"; exit 1; fi
