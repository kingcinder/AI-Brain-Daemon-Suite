#!/bin/bash
# test_glymphatic_clearance.sh — unit tests for the glymphatic organ
# (systemic clearance), created 2026-11-20 under Amendment 3 of the
# Gated-Ingress Refactor. Fixture workspace: an overstayed pending
# queue, a stale gate lease, an old + a fresh dead letter.
# Asserts: escalation (not removal) of the organ-owned queue, lease
# reaping, dead-letter archiving, ledger completeness, conservation
# identity, and the reader's lastConsultedAt stamp.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
FAILS=0
ok()   { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

mkdir -p "$FIX/core/gate" "$FIX/memory/gate-leases" "$FIX/queue/deadletter" "$FIX/skills"
cp "$ROOT/core/gate/store_write.py" "$FIX/core/gate/"
OLD_TS="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FIX/core/gate/flows.json" <<EOF
{"flows": [{"id": "fixture-pending", "store": "memory/pending-fixture.json",
            "producer": "fixture", "reader": "fixture", "sla_seconds": 3600,
            "semantics": "merge"}], "internal_stores": []}
EOF
cat > "$FIX/memory/pending-fixture.json" <<EOF
{"pending": [{"id": "old1", "timestamp": "$OLD_TS"}, {"id": "new1", "timestamp": "$NOW_TS"}], "created": "2026-01-01"}
EOF
BOOT="$(cat /proc/sys/kernel/random/boot_id)"
cat > "$FIX/memory/gate-leases/stale.json" <<EOF
{"name": "stale", "pid": 999999, "boot_id": "$BOOT", "proc_start": 1, "acquired_at": "$OLD_TS"}
EOF
echo '{"task": "old"}' > "$FIX/queue/deadletter/old.json"
touch -d '10 days ago' "$FIX/queue/deadletter/old.json"
echo '{"task": "new"}' > "$FIX/queue/deadletter/new.json"
# A LIVE lease (this test process, correct string start time) must be
# retained — regression cover for the int/string proc_start bug that
# made the first live sweep reap the real daemon/keeper leases.
MYSTART="$(awk '{print $22}' /proc/$$/stat)"
cat > "$FIX/memory/gate-leases/live.json" <<EOF
{"name": "live", "pid": $$, "boot_id": "$BOOT", "proc_start": "$MYSTART", "acquired_at": "$NOW_TS"}
EOF
echo '{"version": "1.0", "lastConsultedAt": null, "totals": {"sweeps": 0, "archived": 0, "reaped": 0, "escalated": 0, "orphansReported": 0}}' > "$FIX/memory/glymphatic-state.json"

OUT="$(WORKSPACE="$FIX" GLYMPHATIC_QUEUE_DIR="$FIX/queue" python3 "$ROOT/skills/glymphatic-memory/scripts/clearance-sweep.py" 2>&1)"
echo "$OUT" | head -3
echo "$OUT" | grep -q "conservation: OK" && ok "conservation identity holds" || bad "conservation identity"
[ ! -f "$FIX/memory/gate-leases/stale.json" ] && ok "stale lease reaped" || bad "stale lease not reaped"
[ -f "$FIX/memory/gate-leases/live.json" ] && ok "live lease retained (proc_start type regression)" || bad "live lease wrongly reaped"
[ -f "$FIX/memory/clearance-archive/$(date -u +%F)/old.json" ] && ok "old dead letter archived" || bad "old dead letter not archived"
[ -f "$FIX/queue/deadletter/new.json" ] && ok "fresh dead letter retained" || bad "fresh dead letter wrongly moved"
[ -f "$FIX/memory/pending-fixture.json" ] && ok "overstayed queue NOT removed (escalation only)" || bad "queue removed!"
LEDGER="$FIX/memory/clearance-ledger.jsonl"
for action in escalate-overstay archive-deadletter reap-lease; do
  grep -q "\"action\": \"$action\"" "$LEDGER" && ok "ledger records $action" || bad "ledger missing $action"
done
TOTALS="$(python3 -c "import json; t=json.load(open('$FIX/memory/glymphatic-state.json'))['totals']; print(t['sweeps'], t['archived'], t['reaped'], t['escalated'])")"
[ "$TOTALS" = "1 1 1 1" ] && ok "state totals updated (1 1 1 1)" || bad "state totals: $TOTALS"

# Reader stamps lastConsultedAt
WORKSPACE="$FIX" bash "$ROOT/skills/glymphatic-memory/scripts/sync-state.sh" >/dev/null 2>&1
WORKSPACE="$FIX" bash "$ROOT/skills/glymphatic-memory/scripts/read-state.sh" >/dev/null 2>&1
STAMP="$(python3 -c "import json; print(json.load(open('$FIX/memory/glymphatic-state.json')).get('lastConsultedAt'))")"
[ "$STAMP" != "None" ] && [ -n "$STAMP" ] && ok "reader stamps lastConsultedAt" || bad "reader stamp missing"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "glymphatic: ALL PASS"; exit 0; else echo "glymphatic: $FAILS FAILURES"; exit 1; fi
