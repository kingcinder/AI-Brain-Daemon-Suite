#!/bin/bash
# test_juno_proposal_modes.sh — Tests for Juno proposal generation.
#
# Validates:
#   1. --emit-target works (outcome-driven target resolution)
#   2. --full-patch flag is recognized
#   3. Full generation round-trip: the generator asks Juno through the helm
#      queue (a fake Juno drainer answers) and stores her proposal
#   4. JUNO_FULL_PATCH env var is respected (dry-run shows full-patch mode)
#   5. Proposal schema validation (content vs insert_lines modes)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS=$(mktemp -d)
trap 'rm -f "$WS/drainer.on" 2>/dev/null; rm -rf "$WS"' EXIT
mkdir -p "$WS/memory" "$WS/bin"
export PATH="$HOME/.local/bin:$PATH"

PASS=0; FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
GEN="$ROOT/core/self-mod/generate-proposals-juno.sh"

# ── 1. --emit-target resolves outcome-driven target ────────────────────────
echo "Test 1: --emit-target resolves target module"
RESULT=$(WORKSPACE="$WS" bash "$GEN" \
  --suite-root "$ROOT" --workspace "$WS" --emit-target 2>/dev/null)
if echo "$RESULT" | python3 -m json.tool >/dev/null 2>&1; then
    MODULE=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['module'])")
    TARGET=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['target'])")
    STEERED=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['steered_by'])")
    pass "emit-target: module=$MODULE target=$TARGET steered=$STEERED"
else
    fail "emit-target did not produce valid JSON"
fi

# ── 2. --full-patch flag is recognized ─────────────────────────────────────
echo "Test 2: --full-patch flag accepted"
if WORKSPACE="$WS" bash "$GEN" \
  --suite-root "$ROOT" --workspace "$WS" --full-patch --emit-target 2>/dev/null; then
    pass "--full-patch accepted (emit-target succeeded)"
else
    fail "--full-patch flag not recognized"
fi

# ── 3. Full generation round-trip through the helm queue ───────────────────
echo "Test 3: generation asks Juno via the queue and stores her proposal"
# The parser validates Juno's target against the steered module/target, so
# resolve steering first and have the drainer answer for exactly that target.
python3 - "$WS/reply.json" << 'PYEOF'
import json, sys
out = sys.argv[1]
json.dump({"proposal_id": "prop_drainer_test", "module": "thalamus-memory",
           "target_paths": ["skills/thalamus-memory/scripts/gate.sh"],
           "insert_after_line": 5,
           "insert_lines": ["# V4-juno-gen: drainer annotation"],
           "description": "drainer test proposal", "risk": "low"}, open(out, "w"))
PYEOF
cat > "$WS/bin/fake-drainer.sh" << 'EOF'
#!/bin/bash
WS="$1"
while [ -f "$WS/drainer.on" ]; do
  OC="$(command -v openclaw || echo "$HOME/.local/bin/openclaw")"
  BRAIN_WORKSPACE="$WS" WORKSPACE="$WS" "$OC" drain:next --limit 5 2>/dev/null | while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r 'select(.type=="juno") | .id // empty' 2>/dev/null)
    [ -z "$id" ] && continue
    BRAIN_WORKSPACE="$WS" WORKSPACE="$WS" "$OC" drain:respond "$id" < "$WS/reply.json" >/dev/null 2>&1
  done
  sleep 0.3
done
EOF
chmod +x "$WS/bin/fake-drainer.sh"
touch "$WS/drainer.on"
bash "$WS/bin/fake-drainer.sh" "$WS" &
DRAINER_PID=$!
GEN_OUT=$(JUNO_PROPOSAL_TIMEOUT=60 WORKSPACE="$WS" bash "$GEN" \
  --suite-root "$ROOT" --workspace "$WS" \
  --module thalamus-memory --target skills/thalamus-memory/scripts/gate.sh 2>&1 || true)
rm -f "$WS/drainer.on"; wait "$DRAINER_PID" 2>/dev/null || true
PROP_FILE="$WS/memory/self-mod/proposals/prop_drainer_test.json"
if [ -f "$PROP_FILE" ] && grep -q "V4-juno-gen: drainer annotation" "$PROP_FILE" \
   && grep -q '"source": "juno"' "$PROP_FILE" \
   && [ -f "$WS/memory/self-mod/last-juno-proposal.json" ]; then
    pass "Juno's proposal stored via the queue round-trip ($(basename "$PROP_FILE"))"
else
    fail "queue generation round-trip: $GEN_OUT"
fi

# ── 4. JUNO_FULL_PATCH env var is respected ────────────────────────────────
echo "Test 4: JUNO_FULL_PATCH=1 accepted (dry-run generates, stores nothing)"
# Dry-run still asks Juno (original semantics) but must not store: swap the
# drainer reply to a content-mode (full-patch) proposal, snapshot the store,
# run --dry-run with the drainer up, and verify nothing was stored.
python3 - "$WS/reply.json" << 'PYEOF'
import json, sys
out = sys.argv[1]
json.dump({"proposal_id": "prop_drainer_patch", "module": "thalamus-memory",
           "target_paths": ["skills/thalamus-memory/scripts/gate.sh"],
           "content": "#!/bin/bash\n# V4-juno-gen: drainer annotation\necho full-patch-ok",
           "description": "drainer full-patch proposal", "risk": "low"}, open(out, "w"))
PYEOF
PENDING_BEFORE=$({ ls "$WS"/memory/self-mod/proposals/*.json 2>/dev/null || true; } | wc -l)
cp "$WS/memory/self-mod/last-juno-proposal.json" "$WS/last-before.json" 2>/dev/null || true
touch "$WS/drainer.on"
bash "$WS/bin/fake-drainer.sh" "$WS" &
DRAINER_PID=$!
DRY=$(JUNO_FULL_PATCH=1 JUNO_PROPOSAL_TIMEOUT=60 WORKSPACE="$WS" bash "$GEN" \
  --suite-root "$ROOT" --workspace "$WS" --dry-run \
  --module thalamus-memory --target skills/thalamus-memory/scripts/gate.sh 2>&1 || true)
rm -f "$WS/drainer.on"; wait "$DRAINER_PID" 2>/dev/null || true
PENDING_AFTER=$({ ls "$WS"/memory/self-mod/proposals/*.json 2>/dev/null || true; } | wc -l)
if echo "$DRY" | grep -q '"content"' && [ "$PENDING_AFTER" -eq "$PENDING_BEFORE" ] \
   && cmp -s "$WS/memory/self-mod/last-juno-proposal.json" "$WS/last-before.json"; then
    pass "JUNO_FULL_PATCH=1 accepted (dry-run produced a content proposal, stored nothing)"
else
    fail "JUNO_FULL_PATCH dry-run semantics: pending $PENDING_BEFORE->$PENDING_AFTER; out: $DRY"
fi

# ── 5. Proposal store accepts both modes ───────────────────────────────────
echo "Test 5: Proposal store handles content-based proposals"
STORE_SH="$ROOT/core/self-mod/proposal-store.sh"
# Store a comment-only proposal
COMMENT_PROP=$(mktemp)
cat > "$COMMENT_PROP" << 'EOF'
{
  "proposal_id": "prop_comment_test",
  "module": "thalamus-memory",
  "target_paths": ["skills/thalamus-memory/scripts/gate.sh"],
  "insert_after_line": 5,
  "insert_lines": ["# V4-juno-gen: test annotation"]
}
EOF
STORED=$(WORKSPACE="$WS" bash "$STORE_SH" add --file "$COMMENT_PROP" 2>/dev/null || echo "STORE_FAIL")
if [ "$STORED" != "STORE_FAIL" ]; then
    pass "comment-only proposal stored"
else
    fail "comment-only proposal store failed"
fi

# Store a content-based proposal (full-patch mode)
CONTENT_PROP=$(mktemp)
cat > "$CONTENT_PROP" << 'EOF'
{
  "proposal_id": "prop_content_test",
  "module": "thalamus-memory",
  "target_paths": ["skills/thalamus-memory/scripts/gate.sh"],
  "description": "Test full-patch proposal",
  "content": "#!/bin/bash\n# test content proposal\necho hello"
}
EOF
STORED2=$(WORKSPACE="$WS" bash "$STORE_SH" add --file "$CONTENT_PROP" 2>/dev/null || echo "STORE_FAIL")
if [ "$STORED2" != "STORE_FAIL" ]; then
    pass "content-based proposal stored"
else
    fail "content-based proposal store failed"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────"
echo "Juno Proposal Mode Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
exit "$FAIL"
