#!/bin/bash
# test_files_map_gate.sh — Regression: check-target/apply-patch must gate EVERY
# write path a proposal can carry, not just target_paths.
#
# Guards the audit finding: a proposal with benign target_paths + a `files`
# map entry pointing at an Immutable Core path (or a patch_unified diff
# touching one) previously slipped past check-target — apply-patch wrote
# whatever the files map / diff said. Now:
#   * check-target.sh validates files-map keys AND patch_unified diff targets
#     through the same immutable / manifest / suite-escape gates as targets.
#   * apply-patch.sh re-checks every write against the resolved path
#     (symlink targets resolve to the file actually written) as
#     defense-in-depth — never skippable.
#
# Run: bash tests/test_files_map_gate.sh
# Requires: python3, jq (both in the Suite's dependency set)

set -euo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/core/self-mod/check-target.sh"
APPLY="$ROOT/core/self-mod/apply-patch.sh"
WS="$(mktemp -d)"
FAKE="$WS/suite"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

cleanup() {
    rm -rf "$WS"
}
trap cleanup EXIT

# ── Build a fake suite with one MUTABLE skill ───────────────────────────
mkdir -p "$FAKE/skills/probe-memory/scripts" "$FAKE/core/locks" "$FAKE/core/concurrency"
# A benign, mutable module (immutable:false, schema 1).
cat > "$FAKE/skills/probe-memory/capability-manifest.json" << 'EOF'
{"schema":1,"module":"probe-memory","immutable":false,"tests":[]}
EOF
# Immutable-core stand-ins under the fake suite (real list is repo-global,
# so these don't even need to be in the fake — but keep them for clarity).
echo "#!/bin/bash" > "$FAKE/core/locks/rwlock.sh"
echo "#!/bin/bash" > "$FAKE/core/concurrency/semaphore.sh"

# A helper that runs check-target on a proposal and reports its verdict.
# check-target reads the REAL immutable-paths.list from its own directory,
# so core/locks/* and core/self-mod/* are immutable regardless of --suite-root.
check_target() { # file  → 0 if ACCEPTED, 1 if REJECTED
    bash "$CHECK" --suite-root "$FAKE" --proposal "$1" >/dev/null 2>&1
}

# ── Test 1: benign proposal still passes ────────────────────────────────
echo "Test 1: benign single-target proposal passes the gate"
cat > "$WS/benign.json" << 'EOF'
{
  "proposal_id": "p_benign",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/new.sh"],
  "content": "#!/bin/bash\necho ok\n"
}
EOF
if check_target "$WS/benign.json"; then
    pass "benign proposal accepted"
else
    fail "benign proposal rejected"
fi

# ── Test 2: files-map smuggling an immutable write is REJECTED ───────────
echo "Test 2: files map pointing at Immutable Core is rejected"
cat > "$WS/files-bypass.json" << 'EOF'
{
  "proposal_id": "p_files",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/new.sh"],
  "files": {
    "core/locks/rwlock.sh": "#!/bin/bash\nevil\n",
    "skills/probe-memory/scripts/new.sh": "#!/bin/bash\necho fine\n"
  }
}
EOF
if check_target "$WS/files-bypass.json"; then
    fail "files-map immutable write was ACCEPTED (bypass!)"
else
    pass "files map with immutable core entry rejected"
fi
# And the reason must be the files_map source, not a generic failure.
OUT=$(bash "$CHECK" --suite-root "$FAKE" --proposal "$WS/files-bypass.json" 2>/dev/null || true)
if echo "$OUT" | jq -e '.rejected[] | select(.source == "files_map" and (.reason == "immutable_core" or .reason == "outside_suite_root"))' >/dev/null 2>&1; then
    pass "rejection is attributed to the files_map entry (immutable_core)"
else
    fail "files-map rejection not attributed correctly: $OUT"
fi

# ── Test 3: patch_unified touching an immutable file is REJECTED ─────────
echo "Test 3: patch_unified diff touching Immutable Core is rejected"
cat > "$WS/patch-bypass.json" << 'EOF'
{
  "proposal_id": "p_patch",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/new.sh"],
  "patch_unified": "--- a/core/concurrency/semaphore.sh\n+++ b/core/concurrency/semaphore.sh\n@@ -1 +1 @@\n-#!/bin/bash\n+#!/bin/bash\nevil\n"
}
EOF
if check_target "$WS/patch-bypass.json"; then
    fail "patch_unified immutable write was ACCEPTED (bypass!)"
else
    pass "patch_unified diff touching immutable core rejected"
fi
OUT=$(bash "$CHECK" --suite-root "$FAKE" --proposal "$WS/patch-bypass.json" 2>/dev/null || true)
if echo "$OUT" | jq -e '.rejected[] | select(.source == "patch_unified")' >/dev/null 2>&1; then
    pass "patch_unified rejection attributed to the diff target"
else
    fail "patch_unified rejection not attributed: $OUT"
fi

# ── Test 4: traversal via files map is REJECTED ──────────────────────────
echo "Test 4: files map escaping the suite root is rejected"
cat > "$WS/traversal.json" << 'EOF'
{
  "proposal_id": "p_trav",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/new.sh"],
  "files": {"../../etc/passwd": "root:x:0:0:"}
}
EOF
if check_target "$WS/traversal.json"; then
    fail "traversal write was ACCEPTED (bypass!)"
else
    pass "files map escaping suite root rejected"
fi

# ── Test 5: apply-patch defense-in-depth refuses immutable writes ────────
echo "Test 5: apply-patch refuses immutable writes even if gate were skipped"
if bash "$APPLY" --suite-root "$FAKE" --proposal "$WS/files-bypass.json" >/dev/null 2>&1; then
    fail "apply-patch accepted an immutable files-map write"
else
    pass "apply-patch refused immutable files-map write (defense-in-depth)"
fi
if [ "$(cat "$FAKE/core/locks/rwlock.sh" 2>/dev/null)" = "#!/bin/bash" ]; then
    pass "rwlock.sh untouched by rejected apply"
else
    fail "rwlock.sh was modified despite rejection!"
fi

# ── Test 6: symlink onto an immutable file is refused at write time ──────
echo "Test 6: writing through a symlink that resolves to Immutable Core is refused"
ln -s "$FAKE/core/locks/rwlock.sh" "$FAKE/skills/probe-memory/scripts/link.sh"
cat > "$WS/symlink.json" << 'EOF'
{
  "proposal_id": "p_link",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/link.sh"],
  "content": "#!/bin/bash\nevil\n"
}
EOF
# check-target resolves the symlink: it points inside the suite, and the rel
# name is benign, so the GATE may accept — but apply-patch must refuse once it
# resolves the target to core/locks/rwlock.sh.
if bash "$APPLY" --suite-root "$FAKE" --proposal "$WS/symlink.json" >/dev/null 2>&1; then
    fail "apply-patch wrote through a symlink onto Immutable Core!"
else
    pass "apply-patch refused symlink resolving to immutable core"
fi
if [ "$(cat "$FAKE/core/locks/rwlock.sh" 2>/dev/null)" = "#!/bin/bash" ]; then
    pass "immutable file intact after symlink attempt"
else
    fail "immutable file modified through symlink!"
fi

# ── Test 8: absolute paths are REJECTED, not silently relocated ──────────
echo "Test 8: absolute target path is rejected (no silent relocation)"
cat > "$WS/abs.json" << 'EOF'
{
  "proposal_id": "p_abs",
  "module": "probe-memory",
  "target_paths": ["/etc/passwd"],
  "content": "root:x:0:0:\n"
}
EOF
if check_target "$WS/abs.json"; then
    fail "absolute target_paths was ACCEPTED (silent relocation!)"
else
    pass "absolute target_paths rejected"
fi
# And via the files map too.
cat > "$WS/abs-files.json" << 'EOF'
{
  "proposal_id": "p_absf",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/new.sh"],
  "files": {"/etc/passwd": "root:x:0:0:\n"}
}
EOF
if check_target "$WS/abs-files.json"; then
    fail "absolute files-map key was ACCEPTED (silent relocation!)"
else
    pass "absolute files-map key rejected"
fi
if bash "$APPLY" --suite-root "$FAKE" --proposal "$WS/abs.json" >/dev/null 2>&1; then
    fail "apply-patch accepted an absolute-path write"
else
    pass "apply-patch refused absolute-path write"
fi
if [ ! -e "$FAKE/etc/passwd" ]; then
    pass "no etc/passwd created inside suite (no relocation)"
else
    fail "absolute path was relocated into the suite!"
fi

# ── Test 9: patch_unified with a NON-git header cannot bypass via -p1 ────
# `patch -p1` strips exactly ONE leading path component from every header.
# A header written as "x/core/concurrency/semaphore.sh" (no git a/ b/
# prefix) lands on core/concurrency/semaphore.sh — an immutable path. The
# gate must catch the -p1 form, not just git-style a//b/ headers.
echo "Test 9: patch_unified non-git header escaping to immutable via -p1 is rejected"
cat > "$WS/patch-nongit.json" << 'EOF'
{
  "proposal_id": "p_patchng",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/new.sh"],
  "patch_unified": "--- x/core/concurrency/semaphore.sh\n+++ x/core/concurrency/semaphore.sh\n@@ -1 +1 @@\n-#!/bin/bash\n+#!/bin/bash\nevil\n"
}
EOF
if check_target "$WS/patch-nongit.json"; then
    fail "non-git patch header escaping to immutable via -p1 was ACCEPTED (bypass!)"
else
    pass "patch_unified -p1 escape to immutable rejected"
fi
OUT=$(bash "$CHECK" --suite-root "$FAKE" --proposal "$WS/patch-nongit.json" 2>/dev/null || true)
if echo "$OUT" | jq -e '.rejected[] | select(.source == "patch_unified")' >/dev/null 2>&1; then
    pass "non-git patch rejection attributed to the diff target"
else
    fail "non-git patch rejection not attributed: $OUT"
fi
if bash "$APPLY" --suite-root "$FAKE" --proposal "$WS/patch-nongit.json" >/dev/null 2>&1; then
    fail "apply-patch accepted non-git -p1 immutable escape"
else
    pass "apply-patch refused non-git -p1 immutable escape (defense-in-depth)"
fi
if [ "$(cat "$FAKE/core/concurrency/semaphore.sh" 2>/dev/null)" = "#!/bin/bash" ]; then
    pass "immutable semaphore.sh intact after non-git patch attempt"
else
    fail "semaphore.sh was modified through non-git patch header!"
fi

# ── Test 7: benign files-map (M6 new-file) applies end to end ────────────
echo "Test 7: benign files map applies end to end"
cat > "$WS/benign-files.json" << 'EOF'
{
  "proposal_id": "p_files_ok",
  "module": "probe-memory",
  "target_paths": ["skills/probe-memory/scripts/extra.sh"],
  "files": {"skills/probe-memory/scripts/extra.sh": "#!/bin/bash\necho extra\n"}
}
EOF
if check_target "$WS/benign-files.json"; then
    pass "benign files map accepted by gate"
else
    fail "benign files map rejected by gate"
fi
if bash "$APPLY" --suite-root "$FAKE" --proposal "$WS/benign-files.json" >/dev/null 2>&1; then
    pass "benign files map applied"
else
    fail "benign files map failed to apply"
fi
if [ "$(cat "$FAKE/skills/probe-memory/scripts/extra.sh" 2>/dev/null)" = "#!/bin/bash
echo extra" ]; then
    pass "applied file content matches"
else
    fail "applied file content mismatch: $(cat "$FAKE/skills/probe-memory/scripts/extra.sh" 2>/dev/null)"
fi

echo ""
echo "Files-map gate tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
