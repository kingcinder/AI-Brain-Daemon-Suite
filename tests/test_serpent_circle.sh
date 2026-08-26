#!/bin/bash
# test_serpent_circle.sh — unit test for the Serpent Circle meta-skillchain skill.
# Hermetic: runs --dry-run against a temp repo it creates itself; never touches
# the real repo, never commits, never pushes.
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

# 7. --dry-run in a temp repo: 6-stage plan, no execution, no commit
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
