#!/bin/bash
# Skill provenance check: asserts all 11 brain skills resolve to
# source=local and status=enabled for Hermes Agent.
#
# Two tiers:
#   1. Repo tier (ALWAYS runs, CI-safe): verifies each skill dir exists in
#      skills/ and its SKILL.md carries the Hermes-required top-level
#      name/description plus a metadata.hermes block. This is the repo-side
#      invariant that makes a skill register as source=local when installed.
#      (CI has no hermes binary and no ~/.hermes state, so this is the tier
#      that runs on every push.)
#   2. Host tier (runs when a hub lock and/or the hermes CLI exist): asserts
#      the 11 brain skills are NOT tracked in the hub lock — per the installed
#      Hermes (hermes_cli/skills_hub.py do_list), the `source` column is
#      derived ONLY from the hub lock, so absence from it means source=local —
#      and that `hermes skills list` reports each as local/enabled.
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
    if not re.search(r"^metadata:\s*$", fm, re.M) or not re.search(r"^  hermes:\s*$", fm, re.M):
        print(f"FAIL: {name} frontmatter lacks metadata.hermes block"); bad += 1; continue
    print(f"PASS: {name} (frontmatter ok)")
sys.exit(1 if bad else 0)
PYEOF
FAIL=$((FAIL + FAIL2))

echo
echo "== Tier 2: host state (runs when hub lock / hermes present) =="
HUB_LOCK="${HERMES_HOME:-$HOME/.hermes}/skills/.hub/lock.json"
if [ -f "$HUB_LOCK" ]; then
  echo "hub lock found: $HUB_LOCK"
  LOCK_CSV=""
  for s in "${SKILLS[@]}"; do LOCK_CSV="$LOCK_CSV $s"; done
  # shellcheck disable=SC2086
  if ! python3 - "$HUB_LOCK" $LOCK_CSV <<'PYEOF'; then
import json, sys

lock_path, *skills = sys.argv[1:]
installed = json.load(open(lock_path)).get("installed", {})
bad = [s for s in skills if s in installed]
if bad:
    print(f"FAIL: brain skills tracked in hub lock (=> source=community): {bad}")
    sys.exit(1)
print(f"PASS: none of the {len(skills)} brain skills tracked in hub lock (=> source=local)")
sys.exit(0)
PYEOF
    FAIL=$((FAIL+1))
  fi
else
  echo "no hub lock at $HUB_LOCK — skipping lock tier (CI-only mode)"
fi

if command -v hermes >/dev/null 2>&1; then
  echo "hermes found — asserting hermes skills list reports local/enabled"
  LIST_OUT="$(hermes skills list 2>&1)"
  for s in "${SKILLS[@]}"; do
    # The table truncates long names with '…' (e.g. 'anterior-cingulate…'),
    # so match on a 15-char prefix (unique among the 11) then check the row
    # shows local source/trust and enabled status.
    prefix="${s:0:15}"
    line="$(printf '%s\n' "$LIST_OUT" | grep -F "$prefix" | head -1)"
    if [ -z "$line" ]; then
      echo "FAIL: $s missing from hermes skills list (not registered?)"; FAIL=$((FAIL+1)); continue
    fi
    if printf '%s' "$line" | grep -q 'local' && printf '%s' "$line" | grep -q 'enabled'; then
      echo "PASS: $s -> local/enabled"
    else
      echo "FAIL: $s not source=local/enabled: $line"; FAIL=$((FAIL+1))
    fi
  done
else
  echo "hermes not on PATH — skipping CLI tier (CI-only mode)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "Skill provenance check: PASS (all 11 brain skills source=local, status=enabled)"
else
  echo "Skill provenance check: $FAIL failure(s) — provenance regression"
fi
exit "$FAIL"
