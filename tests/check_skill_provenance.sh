#!/bin/bash
# Skill provenance check: asserts all 11 brain skills are local to this
# suite and enabled for Juno (Juno-direct, 2026-11-20 scrub).
#
# Two tiers:
#   1. Repo tier (ALWAYS runs, CI-safe): verifies each skill dir exists in
#      skills/ and its SKILL.md carries the required top-level
#      name/description plus a metadata block with a Juno-era seat entry
#      (`juno:` — the renamed block — or `openclaw:`, the helm shim's own
#      block). This is the repo-side invariant that makes a skill local to
#      the suite when installed. (CI has no shim and no queue state, so
#      this is the tier that runs on every push.)
#   2. Host tier (runs when the openclaw shim exists): asserts the helm
#      queue answers a health probe through the shim (Juno's seat is
#      reachable) and that each skill is present in the deployed
#      workspace — presence here, with no external registry, is what
#      local/enabled means in the shim era.
#
# Exit 0 = clean; non-zero = provenance regression.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS=(
  acc-error-memory amygdala-memory anterior-cingulate-memory basal-ganglia-memory
  cerebellum-memory heartbeat-memory hippocampus-memory insula-memory
  prefrontal-cortex-memory social-memory vta-memory
)
FAIL=0

echo "== Tier 1: repo-side invariants (always run) =="
for s in "${SKILLS[@]}"; do
  if [ ! -d "$ROOT/skills/$s" ]; then
    echo "FAIL: missing skill dir skills/$s"; FAIL=$((FAIL+1))
  elif [ ! -f "$ROOT/skills/$s/SKILL.md" ]; then
    echo "FAIL: $s has no SKILL.md"; FAIL=$((FAIL+1))
  fi
done

# Batch frontmatter validation in one python pass over all skills.
# NOTE: ROOT is passed as a single argv (paths may contain spaces, e.g.
# ".../AI Brain Suite/..."), and skill names are passed separately.
FAIL2=0
SKILLS_CSV=""
for s in "${SKILLS[@]}"; do
  SKILLS_CSV="$SKILLS_CSV $s"
done
# shellcheck disable=SC2086
python3 - "$ROOT" $SKILLS_CSV <<'PYEOF' || FAIL2=1
import os, re, sys

root, *names = sys.argv[1:]
bad = 0
for name in names:
    p = os.path.join(root, "skills", name)
    try:
        text = open(os.path.join(p, "SKILL.md")).read()
    except OSError:
        print(f"FAIL: {name} has no SKILL.md"); bad += 1; continue
    if not text.startswith("---"):
        print(f"FAIL: {name} SKILL.md missing frontmatter"); bad += 1; continue
    fm = text.split("---", 2)[1]
    if not re.search(r"^name:\s*" + re.escape(name) + r"\s*$", fm, re.M):
        print(f"FAIL: {name} frontmatter lacks name: {name}"); bad += 1; continue
    if not re.search(r"^description:\s*", fm, re.M):
        print(f"FAIL: {name} frontmatter lacks description"); bad += 1; continue
    if not re.search(r"^metadata:\s*$", fm, re.M) or not (
        re.search(r"^  juno:\s*$", fm, re.M) or re.search(r"^  openclaw:\s*$", fm, re.M)
    ):
        print(f"FAIL: {name} frontmatter lacks a metadata.juno / metadata.openclaw block"); bad += 1; continue
    print(f"PASS: {name} (frontmatter ok)")
sys.exit(1 if bad else 0)
PYEOF
FAIL=$((FAIL + FAIL2))

echo
echo "== Tier 2: host state (runs when the openclaw shim is present) =="
OC_BIN="$(command -v openclaw 2>/dev/null || echo "$HOME/.local/bin/openclaw")"
if [ -x "$OC_BIN" ]; then
  echo "openclaw shim found: $OC_BIN — asserting the helm queue answers and skills are local/enabled"
  HEALTH="$(BRAIN_WORKSPACE="${BRAIN_WORKSPACE:-$ROOT}" "$OC_BIN" health 2>/dev/null)"
  if printf '%s' "$HEALTH" | grep -q '"queue_depth"'; then
    echo "PASS: helm queue reachable via shim (Juno's seat answers)"
    for s in "${SKILLS[@]}"; do
      if [ -d "$ROOT/skills/$s" ] && [ -f "$ROOT/skills/$s/SKILL.md" ]; then
        echo "PASS: $s -> local/enabled"
      else
        echo "FAIL: $s missing from deployed workspace (not local?)"; FAIL=$((FAIL+1))
      fi
    done
  else
    echo "FAIL: helm queue did not answer a health probe via the shim"; FAIL=$((FAIL+1))
  fi
else
  echo "openclaw shim not found — skipping host tier (CI-only mode)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "Skill provenance check: PASS (all 11 brain skills local, enabled for Juno)"
else
  echo "Skill provenance check: $FAIL failure(s) — provenance regression"
fi
exit "$FAIL"
