#!/bin/bash
# test_serpent_circle.sh — unit test for the Serpent Circle meta-skillchain skill.
# Hermetic: runs against a temp repo it creates itself; never touches the real
# repo, never commits, never pushes.
#
# STANDING POLICY: the skill RUNS FOR REAL whenever invoked (no mode flags =
# real run). --dry-run remains available only as an explicit opt-in.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/serpent-circle"
ORCH="$SKILL/scripts/serpent-circle.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }

# 1. skill files present
for f in SKILL.md references/chain-protocol.md references/perf-optimization.md \
    scripts/serpent-circle.sh capability-manifest.json; do
    if [ -f "$SKILL/$f" ]; then
        ok "file exists: $f"
    else
        bad "file missing: $f"
    fi
done

# 2. SKILL.md frontmatter: name + trigger phrases
if grep -q '^name: serpent-circle' "$SKILL/SKILL.md" 2>/dev/null \
    && grep -qi 'tidy up' "$SKILL/SKILL.md" 2>/dev/null \
    && grep -qi 'clean house' "$SKILL/SKILL.md" 2>/dev/null; then
    ok "SKILL.md has name + trigger phrases"
else
    bad "SKILL.md frontmatter/triggers missing"
fi

# 3. manifest validates against the schema
if [ -x "$ROOT/core/schema/validate-manifest.sh" ]; then
    if bash "$ROOT/core/schema/validate-manifest.sh" "$SKILL/capability-manifest.json" >/dev/null 2>&1; then
        ok "manifest validates"
    else
        bad "manifest fails validation"
    fi
else
    ok "skipped manifest validation (script absent)"
fi

# 4. orchestrator syntax
if bash -n "$ORCH" 2>/dev/null; then
    ok "orchestrator syntax OK"
else
    bad "orchestrator syntax error"
fi

# 5. --help exits 0
if bash "$ORCH" --help >/dev/null 2>&1; then
    ok "--help exits 0"
else
    bad "--help failed"
fi

# 6. --self-test exits 0
if bash "$ORCH" --self-test >/dev/null 2>&1; then
    ok "--self-test OK"
else
    bad "--self-test failed"
fi

# 7. REAL RUN (no mode flags) in a temp repo: scaffolds workspace, writes
#    inventory + plan labeled REAL RUN, state dry_run:false, and still never
#    commits (the script itself only scaffolds; the agent drives the chain).
TMP2="$(mktemp -d)"
trap 'rm -rf "${TMP:-}" "${TMP2:-}"' EXIT
mkdir -p "$TMP2/proj"
printf '#!/bin/bash\necho hi\n' > "$TMP2/proj/tool.sh"
printf '.serpent-circle/\n' > "$TMP2/proj/.gitignore"
git -C "$TMP2/proj" init -q 2>/dev/null || true
git -C "$TMP2/proj" add . >/dev/null 2>&1 || true
git -C "$TMP2/proj" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1 || true

REAL_OUT="$TMP2/real.out"
if bash "$ORCH" --repo "$TMP2/proj" >"$REAL_OUT" 2>&1; then
    ok "real run (default, no flags) exits 0"
else
    bad "real run failed"; cat "$REAL_OUT"
fi
if grep -q 'REAL RUN' "$REAL_OUT" 2>/dev/null; then
    ok "real run banner printed"
else
    bad "real run banner missing"; tail -5 "$REAL_OUT"
fi
REAL_PLAN="$TMP2/proj/.serpent-circle/chain-plan.md"
if [ -f "$REAL_PLAN" ] && grep -q 'REAL RUN' "$REAL_PLAN" 2>/dev/null; then
    ok "real run plan labeled REAL RUN"
else
    bad "real run plan missing/not labeled REAL RUN"
fi
if [ -f "$TMP2/proj/.serpent-circle/state.json" ] \
    && grep -q '"dry_run": false' "$TMP2/proj/.serpent-circle/state.json" 2>/dev/null; then
    ok "real run state.json records dry_run:false"
else
    bad "real run state.json missing or not dry_run:false"
fi
if [ "$(git -C "$TMP2/proj" rev-list --count HEAD 2>/dev/null || echo 0)" = "1" ]; then
    ok "real run scaffold created no commit"
else
    bad "real run scaffold changed commit count"
fi
if [ -z "$(git -C "$TMP2/proj" status --porcelain)" ]; then
    ok "real run scaffold left git status clean"
else
    bad "real run scaffold polluted git status"
fi

# 8. --dry-run remains available as an explicit opt-in and stays hermetic
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP2"' EXIT
mkdir -p "$TMP/proj/legacy-IGNORE" "$TMP/proj/pkg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj/legacy-IGNORE" "$TMP/proj/pkg"
printf '#!/bin/bash\necho hi\n' > "$TMP/proj/tool.sh"
printf 'import os\n' > "$TMP/proj/main.py"
printf 'function f(){return 1}\n' > "$TMP/proj/app.js"
printf 'junk\n' > "$TMP/proj/notes.bak"
printf 'x\n' > "$TMP/proj/legacy-IGNORE/old.sh"
# The chain workspace must be gitignored — lock that guarantee in.
printf '.serpent-circle/\n' > "$TMP/proj/.gitignore"
git -C "$TMP/proj" init -q 2>/dev/null || true
git -C "$TMP/proj" add . >/dev/null 2>&1 || true
git -C "$TMP/proj" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1 || true

DRY_OUT="$TMP/dry.out"
if bash "$ORCH" --dry-run --repo "$TMP/proj" >"$DRY_OUT" 2>&1; then
    ok "--dry-run exits 0"
else
    bad "--dry-run failed"; cat "$DRY_OUT"
fi

PLAN="$TMP/proj/.serpent-circle/chain-plan.md"
if [ -f "$PLAN" ]; then
    ok "chain-plan.md created"
else
    bad "chain-plan.md missing"
fi
for s in "Stage 1" "Stage 2" "Stage 3" "Stage 4" "Stage 5" "Stage 6"; do
    if grep -q "$s" "$PLAN" 2>/dev/null; then
        ok "plan includes $s"
    else
        bad "plan missing $s"
    fi
done
if grep -qi 'commit' "$PLAN" 2>/dev/null && grep -qi 'push' "$PLAN" 2>/dev/null; then
    ok "plan covers commit + push"
else
    bad "plan missing commit/push coverage"
fi
if grep -q 'python' "$PLAN" 2>/dev/null; then
    ok "plan detected python"
else
    bad "plan did not detect python"
fi
if grep -q 'javascript' "$PLAN" 2>/dev/null; then
    ok "plan detected javascript"
else
    bad "plan did not detect javascript"
fi
if grep -qi 'legacy-IGNORE' "$PLAN" 2>/dev/null; then
    ok "plan flagged legacy dir"
else
    bad "plan missed legacy dir"
fi
if [ "$(git -C "$TMP/proj" rev-list --count HEAD 2>/dev/null || echo 0)" = "1" ]; then
    ok "dry-run created no commit (repo stays at the single base commit)"
else
    bad "dry-run changed commit count (expected 1 base commit, found: $(git -C "$TMP/proj" rev-list --count HEAD 2>/dev/null || echo 0))"
fi
# The strongest guarantee: after --dry-run, git status is empty (the chain
# workspace is gitignored, tracked files untouched).
if [ -z "$(git -C "$TMP/proj" status --porcelain)" ]; then
    ok "dry-run left git status clean"
else
    bad "dry-run polluted git status: $(git -C "$TMP/proj" status --porcelain | head -3)"
fi
if [ -f "$TMP/proj/.serpent-circle/state.json" ] \
    && grep -q '"dry_run": true' "$TMP/proj/.serpent-circle/state.json" 2>/dev/null; then
    ok "state.json records dry-run mode"
else
    bad "state.json missing or not dry-run"
fi

echo "serpent-circle: $PASS passed, $FAIL failed"
exit $FAIL
