#!/bin/bash
# test_claustrum_binding.sh — unit tests for the claustrum organ
# (cross-organ binding/coherence), created 2026-11-20 under Phase G
# (Amendment 4) of the Gated-Ingress Refactor. Fixture: three organ
# states — two freshly consulted, one unread for 3 days — plus a
# cortical.json carrying pre-existing themes that must survive.
# Asserts: all organs bound, themes preserved, the stale organ is
# flagged as incoherence + ledgered, state totals update, reader
# stamps lastConsultedAt.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
FAILS=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

mkdir -p "$FIX/core/gate" "$FIX/memory"
cp "$ROOT/core/gate/store_write.py" "$FIX/core/gate/"
FRESH="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STALE="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
echo "{\"lastConsultedAt\": \"$FRESH\", \"lastUpdated\": \"$FRESH\"}" > "$FIX/memory/alpha-state.json"
echo "{\"lastConsultedAt\": \"$FRESH\", \"lastUpdated\": \"$FRESH\"}" > "$FIX/memory/beta-state.json"
echo "{\"lastConsultedAt\": \"$STALE\", \"lastUpdated\": \"$STALE\"}" > "$FIX/memory/gamma-state.json"
echo '{"version": 3, "themes": {"self/work": {"weight": 0.5}}, "replays": []}' > "$FIX/memory/cortical.json"
echo '{"version": "1.0", "lastConsultedAt": null, "totals": {"bindings": 0, "incoherences": 0}}' > "$FIX/memory/claustrum-state.json"

OUT="$(WORKSPACE="$FIX" python3 "$ROOT/skills/claustrum-memory/scripts/bind.py" 2>&1)"
echo "$OUT"
echo "$OUT" | grep -q "3 organs bound; 1 incoherence" && ok "binding counts + incoherence detected" || bad "binding output wrong"
python3 - "$FIX" <<'PY' && ok "cortical binding content correct" || bad "cortical binding content wrong"
import json, sys
d = json.load(open(sys.argv[1] + "/memory/cortical.json"))
assert d["themes"]["self/work"]["weight"] == 0.5, "themes clobbered"
b = d["binding"]
assert b["organCount"] == 3, b["organCount"]
assert set(b["organs"]) == {"alpha", "beta", "gamma"}
incs = b["coherence"]["incoherences"]
assert len(incs) == 1 and incs[0]["organ"] == "gamma", incs
PY
grep -q '"organ": "gamma"' "$FIX/memory/binding-ledger.jsonl" && ok "incoherence ledgered" || bad "incoherence not ledgered"
TOTALS="$(python3 -c "import json; t=json.load(open('$FIX/memory/claustrum-state.json'))['totals']; print(t['bindings'], t['incoherences'])")"
[ "$TOTALS" = "1 1" ] && ok "state totals (1 binding, 1 incoherence)" || bad "state totals: $TOTALS"

WORKSPACE="$FIX" bash "$ROOT/skills/claustrum-memory/scripts/sync-state.sh" >/dev/null 2>&1
WORKSPACE="$FIX" bash "$ROOT/skills/claustrum-memory/scripts/read-state.sh" >/dev/null 2>&1
STAMP="$(python3 -c "import json; print(json.load(open('$FIX/memory/claustrum-state.json')).get('lastConsultedAt'))")"
[ "$STAMP" != "None" ] && [ -n "$STAMP" ] && ok "reader stamps lastConsultedAt" || bad "reader stamp missing"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "claustrum: ALL PASS"; exit 0; else echo "claustrum: $FAILS FAILURES"; exit 1; fi
