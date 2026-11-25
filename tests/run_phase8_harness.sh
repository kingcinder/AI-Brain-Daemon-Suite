#!/bin/bash
# run_phase8_harness.sh — ROADMAP M6 self-directed expansion regression.
#
# Proves the self-mod pipeline can CREATE a brand-new peripheral module (new
# skill directory + capability-manifest.json + scripts + tests), not just
# patch an existing one, under the same check-target → evaluate → deploy →
# rollback gates:
#   * check-target accepts a new_module:true proposal whose proposed manifest
#     is schema-valid, names the same module, and ships every declared test
#     (either in the files map or already present in the suite).
#   * check-target REJECTS: manifest missing from the files map, an invalid
#     proposed manifest (immutable/schema/module-mismatch), and a declared
#     test that isn't shipped.
#   * evaluate accepts the new-module proposal (regression gate green).
#   * deploy creates the module's files live; rollback removes them.
#   * the full run-pipeline flow can propose → evaluate → deploy the new module.
#
# Uses an isolated temp suite + WORKSPACE. Does not touch the real project
# tree (deploy/rollback run only inside the temp suite).
#
# Usage: bash tests/run_phase8_harness.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
SM="$CORE/self-mod"
FAILURES=0
PASSES=0

pass() { echo "  PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
section() { echo ""; echo "=== $1 ==="; }

export WORKSPACE
WORKSPACE=$(mktemp -d)
SUITE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE" "$SUITE"' EXIT

mkdir -p "$WORKSPACE/memory"
chmod +x "$SM"/*.sh 2>/dev/null || true

# ── Build minimal suite under $SUITE (mirrors phase3 fixture) ────────────────
section "fixture-suite"
mkdir -p "$SUITE/skills/demo-mod/scripts" "$SUITE/core" "$SUITE/tests"
for d in self-mod utility locks snapshot provenance sandbox concurrency schema executive-load executive; do
  cp -a "$CORE/$d" "$SUITE/core/" 2>/dev/null || true
done
cp -a "$CORE/capability-registry.schema.json" "$SUITE/core/" 2>/dev/null || true

# Peripheral skill with manifest
cat > "$SUITE/skills/demo-mod/capability-manifest.json" << 'EOF'
{
  "schema": 1,
  "module": "demo-mod",
  "version": "0.1.0",
  "capabilities": ["demo"],
  "inputs": [{"name": "none", "type": "scalar", "source": "n/a", "required": false}],
  "outputs": [{"name": "note", "type": "state_write", "target": "memory/demo-note.txt"}],
  "side_effects": ["filesystem_write"],
  "dependencies": [],
  "tests": [{"path": "tests/run_phase1_harness.sh", "kind": "regression"}],
  "immutable": false
}
EOF
cat > "$SUITE/skills/demo-mod/scripts/hello.sh" << 'EOF'
#!/bin/bash
echo "hello-v1"
EOF
chmod +x "$SUITE/skills/demo-mod/scripts/hello.sh"

# Stub regression harness (always passes; phase1 fallback for the gate)
cat > "$SUITE/tests/run_phase1_harness.sh" << 'EOF'
#!/bin/bash
echo "stub phase1: ok"
exit 0
EOF
chmod +x "$SUITE/tests/run_phase1_harness.sh"

# Immutable core stubs
mkdir -p "$SUITE/core/locks" "$SUITE/core/concurrency" "$SUITE/core/sandbox" "$SUITE/core/executive-load"
echo '# lock' > "$SUITE/core/locks/rwlock.sh"
echo '# sem' > "$SUITE/core/concurrency/semaphore.sh"
echo '# sand' > "$SUITE/core/sandbox/sandbox-run.sh"
echo '# eload' > "$SUITE/core/executive-load/calc-executive-load.sh"

pass "temp suite assembled"

# ── Helper: build a new-module proposal (M6) ─────────────────────────────────
# make_newmod <id> <manifest-module> <tests-in-files: 0|1> <test-exists-in-suite: 0|1>
make_newmod() {
  local id="$1" mm="$2" ship_test="$3" suite_test="$4"
  local f; f=$(mktemp)
  local tests_json
  if [ "$suite_test" = "1" ]; then
    tests_json='[{"path":"tests/run_phase1_harness.sh","kind":"regression"}]'
  else
    tests_json='[{"path":"skills/newmod/tests/test_newmod.sh","kind":"unit"}]'
  fi
  cat > "$f" << EOF
{
  "proposal_id": "$id",
  "module": "$mm",
  "new_module": true,
  "target_paths": [
    "skills/newmod/capability-manifest.json",
    "skills/newmod/scripts/hello.sh",
    "skills/newmod/tests/test_newmod.sh"
  ],
  "files": {
    "skills/newmod/capability-manifest.json": $(printf '%s' "{\"schema\":1,\"module\":\"$mm\",\"version\":\"0.1.0\",\"capabilities\":[\"newmod\"],\"inputs\":[{\"name\":\"none\",\"type\":\"scalar\",\"source\":\"n/a\",\"required\":false}],\"outputs\":[{\"name\":\"note\",\"type\":\"state_write\",\"target\":\"memory/newmod-note.txt\"}],\"side_effects\":[\"filesystem_write\"],\"dependencies\":[],\"tests\":$tests_json,\"immutable\":false}" | jq -Rs .),
    "skills/newmod/scripts/hello.sh": $(printf '%s' "#!/bin/bash\necho newmod-v1\n" | jq -Rs .),
    "skills/newmod/tests/test_newmod.sh": $(printf '%s' "#!/bin/bash\necho newmod test ok\nexit 0\n" | jq -Rs .)
  },
  "estimated_components": {
    "task_success": 0.95,
    "resource_cost": 0.1,
    "error_rate": 0.0,
    "regression_penalty": 0.0
  }
}
EOF
  # If the declared test must NOT ship in files (negative cases), strip it.
  if [ "$ship_test" = "0" ]; then
    python3 - "$f" << 'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["files"].pop("skills/newmod/tests/test_newmod.sh", None)
d["target_paths"] = [t for t in d["target_paths"] if t != "skills/newmod/tests/test_newmod.sh"]
p.write_text(json.dumps(d, indent=2) + "\n")
PY
  fi
  echo "$f"
}

# ── check-target: accept a valid new-module proposal ─────────────────────────
section "M6-check-target-new-module-accepted"
NM_OK=$(make_newmod prop_newmod_ok newmod 1 0)
if bash "$SM/check-target.sh" --suite-root "$SUITE" --proposal "$NM_OK" >/tmp/p8_ct_ok.json 2>/dev/null; then
  if jq -e '.accepted[]?.new_module==true' /tmp/p8_ct_ok.json >/dev/null; then
    pass "check-target accepts a new-module proposal (new_module flagged)"
  else
    fail "check-target accepts new module but new_module flag missing: $(cat /tmp/p8_ct_ok.json)"
  fi
  if jq -e '[.accepted[].target] | index("skills/newmod/capability-manifest.json")' /tmp/p8_ct_ok.json >/dev/null; then
    pass "manifest path accepted as a new-module target"
  else
    fail "manifest path accepted as a new-module target: $(cat /tmp/p8_ct_ok.json)"
  fi
else
  fail "check-target accepts a new-module proposal: $(cat /tmp/p8_ct_ok.json 2>/dev/null)"
fi

# ── check-target: reject manifest missing from files map ─────────────────────
section "M6-check-target-rejects"
NM_NOMAN=$(make_newmod prop_newmod_noman newmod 0 0)
python3 - "$NM_NOMAN" << 'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["files"].pop("skills/newmod/capability-manifest.json", None)
p.write_text(json.dumps(d, indent=2) + "\n")
PY
if ! bash "$SM/check-target.sh" --suite-root "$SUITE" --proposal "$NM_NOMAN" >/tmp/p8_ct_noman.json 2>/dev/null; then
  if jq -e '.rejected[]?.reason | startswith("new_module_missing_manifest")' /tmp/p8_ct_noman.json >/dev/null; then
    pass "rejects new-module proposal missing its manifest in files map"
  else
    fail "rejects missing manifest (got $(cat /tmp/p8_ct_noman.json))"
  fi
else
  fail "rejects new-module proposal missing its manifest"
fi

# Invalid proposed manifest: immutable must be false
NM_BADIMM=$(make_newmod prop_newmod_badimm newmod 1 0)
python3 - "$NM_BADIMM" << 'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["files"]["skills/newmod/capability-manifest.json"] = d["files"]["skills/newmod/capability-manifest.json"].replace('"immutable":false', '"immutable":true')
p.write_text(json.dumps(d, indent=2) + "\n")
PY
if ! bash "$SM/check-target.sh" --suite-root "$SUITE" --proposal "$NM_BADIMM" >/tmp/p8_ct_badimm.json 2>/dev/null; then
  if jq -e '.rejected[]?.reason | contains("new_module_invalid_manifest") and contains("manifest_immutable_not_false")' /tmp/p8_ct_badimm.json >/dev/null; then
    pass "rejects new-module proposal with immutable:true manifest"
  else
    fail "rejects immutable:true manifest (got $(cat /tmp/p8_ct_badimm.json))"
  fi
else
  fail "rejects immutable:true manifest"
fi

# Declared test not shipped and not already in suite
NM_NOTEST=$(make_newmod prop_newmod_notest newmod 0 0)
if ! bash "$SM/check-target.sh" --suite-root "$SUITE" --proposal "$NM_NOTEST" >/tmp/p8_ct_notest.json 2>/dev/null; then
  if jq -e '.rejected[]?.reason | contains("declared_test_not_shipped")' /tmp/p8_ct_notest.json >/dev/null; then
    pass "rejects new module whose declared test isn't shipped or present"
  else
    fail "rejects unshipable declared test (got $(cat /tmp/p8_ct_notest.json))"
  fi
else
  fail "rejects unshipable declared test"
fi

# ── evaluate: accepts the new-module proposal ────────────────────────────────
section "M6-evaluate-new-module"
mkdir -p "$WORKSPACE/memory/self-mod"
echo '{"task_success":0.7,"latency_norm":1.0,"memory_kv_norm":1.0}' > "$WORKSPACE/memory/self-mod/baseline-metrics.json"
EV=$(WORKSPACE="$WORKSPACE" bash "$SM/evaluate-proposal.sh" --proposal "$NM_OK" --suite-root "$SUITE" --workspace "$WORKSPACE" 2>/dev/null)
if echo "$EV" | jq -e '.accepted==true' >/dev/null; then
  pass "evaluate accepts the new-module proposal"
else
  fail "evaluate accepts the new-module proposal ($EV)"
fi

# ── deploy: creates the new module's files live; rollback removes them ───────
section "M6-deploy-rollback-new-module"
if [ ! -f "$SUITE/skills/newmod/scripts/hello.sh" ]; then
  pass "new module absent before deploy (fixture clean)"
else
  fail "new module absent before deploy"
fi
DEP=$(WORKSPACE="$WORKSPACE" bash "$SM/deploy-proposal.sh" \
  --proposal "$NM_OK" --suite-root "$SUITE" --workspace "$WORKSPACE" --skip-eval 2>/tmp/p8_dep_err.$$) || {
  cat /tmp/p8_dep_err.$$ >&2
  fail "deploy exit 0 for new module"
  DEP="{}"
}
rm -f /tmp/p8_dep_err.$$
if [ -f "$SUITE/skills/newmod/capability-manifest.json" ] && [ -f "$SUITE/skills/newmod/scripts/hello.sh" ] && [ -f "$SUITE/skills/newmod/tests/test_newmod.sh" ]; then
  pass "deploy created manifest + script + test for the new module"
else
  fail "deploy created new-module files (manifest=$( [ -f "$SUITE/skills/newmod/capability-manifest.json" ] && echo yes || echo NO ) script=$( [ -f "$SUITE/skills/newmod/scripts/hello.sh" ] && echo yes || echo NO ) test=$( [ -f "$SUITE/skills/newmod/tests/test_newmod.sh" ] && echo yes || echo NO ))"
fi
if jq -e '.module=="newmod"' "$SUITE/skills/newmod/capability-manifest.json" >/dev/null 2>&1; then
  pass "deployed manifest is the new module's (module=newmod)"
else
  fail "deployed manifest module field"
fi
if grep -q 'newmod-v1' "$SUITE/skills/newmod/scripts/hello.sh" 2>/dev/null; then
  pass "deployed new module script carries proposal content"
else
  fail "deployed new module script content"
fi

RB=$(WORKSPACE="$WORKSPACE" bash "$SM/rollback.sh" \
  --proposal-id prop_newmod_ok --suite-root "$SUITE" --workspace "$WORKSPACE" --reason harness 2>/tmp/p8_rb_err.$$) || {
  cat /tmp/p8_rb_err.$$ >&2
  fail "rollback exit 0 for new module"
}
rm -f /tmp/p8_rb_err.$$
if [ ! -f "$SUITE/skills/newmod/capability-manifest.json" ] && [ ! -f "$SUITE/skills/newmod/scripts/hello.sh" ]; then
  pass "rollback removed the new module's files"
else
  fail "rollback removed the new module's files (manifest=$( [ -f "$SUITE/skills/newmod/capability-manifest.json" ] && echo still-there || echo gone ))"
fi
if jq -e '.rolled_back==true' "$WORKSPACE/memory/self-mod/deploys/prop_newmod_ok.json" >/dev/null 2>&1; then
  pass "new-module deploy record marked rolled_back"
else
  fail "new-module deploy record marked rolled_back"
fi

# ── run-pipeline: propose → evaluate → deploy a new module end-to-end ────────
section "M6-pipeline-new-module"
WORKSPACE2=$(mktemp -d)
mkdir -p "$WORKSPACE2/memory/self-mod"
echo '{"task_success":0.7,"latency_norm":1.0,"memory_kv_norm":1.0}' > "$WORKSPACE2/memory/self-mod/baseline-metrics.json"
NM_PIPE=$(make_newmod prop_newmod_pipe newmod 1 0)
PIPE=$(WORKSPACE="$WORKSPACE2" bash "$SM/run-pipeline.sh" \
  --suite-root "$SUITE" --workspace "$WORKSPACE2" --proposal "$NM_PIPE" --top-k 1 2>/tmp/p8_pipe_err.$$) || {
  cat /tmp/p8_pipe_err.$$ >&2
  fail "pipeline exit 0 for new module"
  PIPE="{}"
}
rm -f /tmp/p8_pipe_err.$$
if echo "$PIPE" | jq -e '.pipeline=="phase3-self-mod" and (.evaluations|length)>=1' >/dev/null; then
  pass "pipeline summary structure for new-module proposal"
else
  fail "pipeline summary structure ($PIPE)"
fi
if grep -q 'newmod-v1' "$SUITE/skills/newmod/scripts/hello.sh" 2>/dev/null; then
  pass "pipeline deployed the new module to the suite"
else
  if echo "$PIPE" | jq -e '.deploy.skipped==true' >/dev/null 2>&1; then
    fail "pipeline deploy was skipped ($PIPE)"
  else
    fail "pipeline deployed the new module (got $(cat "$SUITE/skills/newmod/scripts/hello.sh" 2>/dev/null || echo missing))"
  fi
fi
rm -rf "$WORKSPACE2"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Phase 8 harness: $PASSES passed, $FAILURES failed"
echo "=========================================="
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
