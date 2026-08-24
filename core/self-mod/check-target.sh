#!/bin/bash
# check-target.sh — Enforce Immutable Core + Capability Registry on proposal targets.
#
# Usage:
#   check-target.sh --suite-root PATH --target REL_PATH [--module NAME]
#   check-target.sh --suite-root PATH --proposal PATH.json
#
# Exit 0 if all targets are allowed; 1 if any rejected. Prints JSON result.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_ROOT=""
TARGET=""
MODULE=""
PROPOSAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --module) MODULE="$2"; shift 2 ;;
    --proposal) PROPOSAL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SUITE_ROOT="${SUITE_ROOT:-$(cd "$SELF_DIR/../.." && pwd)}"
LIST="$SELF_DIR/immutable-paths.list"

python3 - "$SUITE_ROOT" "$LIST" "$TARGET" "$MODULE" "$PROPOSAL" <<'PY'
import json, os, sys, fnmatch
from pathlib import Path

suite = Path(sys.argv[1]).resolve()
list_path = Path(sys.argv[2])
target_arg = sys.argv[3] or ""
module_arg = sys.argv[4] or ""
proposal_path = sys.argv[5] or ""

immutable = []
for line in list_path.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    immutable.append(line)

targets = []
module = module_arg
prop = None
files_map = {}
new_module = False
if proposal_path:
    prop = json.loads(Path(proposal_path).read_text())
    module = module or prop.get("module") or ""
    tps = prop.get("target_paths") or prop.get("targets") or []
    if isinstance(tps, str):
        tps = [tps]
    targets = list(tps)
    single = prop.get("target") or prop.get("target_path")
    if single:
        targets.append(single)
    fm = prop.get("files")
    files_map = fm if isinstance(fm, dict) else {}
    new_module = bool(prop.get("new_module")) and module != ""
elif target_arg:
    targets = [target_arg]

# ── M6: new-module creation — validate the PROPOSED manifest up front. ─────
# A proposal with new_module:true creates a brand-new skill directory under the
# same gates as patching an existing one. The proposed manifest (from the
# files map, never the live tree) must be schema-valid, name the same module,
# and ship every declared test in the files map — the new module's regression
# harness is REQUIRED before deploy (a declared test that isn't part of the
# proposal would fail the sandbox sweep at evaluate time anyway, so we reject
# it earlier, at the gate).
NEW_MOD_MANIFEST = None  # validated manifest dict once accepted
NEW_MOD_REJECT = None    # (target, reason) if the proposed manifest is invalid
if new_module:
    man_rel = f"skills/{module}/capability-manifest.json"
    if man_rel not in files_map:
        NEW_MOD_REJECT = (man_rel, "new_module_missing_manifest")
    else:
        try:
            cand = json.loads(files_map[man_rel])
        except Exception as e:
            NEW_MOD_REJECT = (man_rel, f"new_module_invalid_manifest_json: {e}")
        else:
            errs = []
            if cand.get("schema") != 1:
                errs.append("schema_not_1")
            if cand.get("immutable") is not False:
                errs.append("manifest_immutable_not_false")
            if cand.get("module") != module:
                errs.append(f"module_mismatch:{cand.get('module')}!= {module}")
            tests = cand.get("tests") or []
            if not isinstance(tests, list) or len(tests) < 1:
                errs.append("tests_min_items_1")
            else:
                for t in tests:
                    tp = (t or {}).get("path", "")
                    # A declared test must be shippable: either it comes in the
                    # proposal's files map, or it already exists in the suite.
                    if tp and tp not in files_map and not (suite / tp).is_file():
                        errs.append(f"declared_test_not_shipped:{tp}")
            if errs:
                NEW_MOD_REJECT = (man_rel, "new_module_invalid_manifest:" + ",".join(errs))
            else:
                NEW_MOD_MANIFEST = cand

def norm(p: str) -> str:
    p = p.replace("\\", "/")
    # Strip leading ./ only (not individual . or / characters — lstrip("./")
    # would turn "../../etc/passwd" into "etc/passwd", bypassing the
    # outside_suite_root check).
    if p.startswith("./"):
        p = p[2:]
    elif p.startswith("."):
        p = p[1:]
    # Strip leading / to make relative
    if p.startswith("/"):
        p = p.lstrip("/")
    return p

def is_immutable(rel: str) -> bool:
    rel = norm(rel)
    for pat in immutable:
        if fnmatch.fnmatch(rel, pat) or rel == pat.rstrip("/*") or rel.startswith(pat.rstrip("*").rstrip("/")):
            # careful: core/self-mod/* should match core/self-mod/foo
            if pat.endswith("/*"):
                prefix = pat[:-1]  # core/self-mod/
                if rel.startswith(prefix) or rel == pat[:-2]:
                    return True
            elif fnmatch.fnmatch(rel, pat) or rel == pat:
                return True
    # decide.sh hard match
    if rel.endswith("prefrontal-cortex-memory/scripts/decide.sh"):
        return True
    return False

def find_manifest(mod: str, rel: str):
    # Prefer skills/<module>/capability-manifest.json
    candidates = []
    if mod:
        candidates.append(suite / "skills" / mod / "capability-manifest.json")
        candidates.append(suite / "core" / mod / "capability-manifest.json")
    # Infer skill dir from path
    parts = Path(rel).parts
    if len(parts) >= 2 and parts[0] == "skills":
        candidates.append(suite / "skills" / parts[1] / "capability-manifest.json")
    if len(parts) >= 2 and parts[0] == "core":
        candidates.append(suite / "core" / parts[1] / "capability-manifest.json")
    for c in candidates:
        if c.is_file():
            return c
    return None

rejected = []
accepted = []
for t in targets:
    rel = norm(t)
    abs_path = (suite / rel).resolve()
    try:
        abs_path.relative_to(suite)
    except ValueError:
        rejected.append({"target": rel, "reason": "outside_suite_root"})
        continue
    if is_immutable(rel):
        rejected.append({"target": rel, "reason": "immutable_core"})
        continue
    # Must not be under core/self-mod even if list missed
    if rel.startswith("core/self-mod/") or rel == "core/self-mod":
        rejected.append({"target": rel, "reason": "immutable_core"})
        continue
    # M6: a brand-new module has no manifest in the live tree yet — its files
    # (manifest, scripts, tests) all live under skills/<module>/ and are accepted
    # iff the proposed manifest validated above. Every target must be inside the
    # new module's directory; immutable guards still apply (checked above).
    if new_module and NEW_MOD_MANIFEST is not None and rel.startswith(f"skills/{module}/"):
        accepted.append({"target": rel, "module": module,
                         "manifest": f"skills/{module}/capability-manifest.json",
                         "new_module": True})
        continue
    man = find_manifest(module, rel)
    if man is None:
        if NEW_MOD_REJECT is not None:
            rejected.append({"target": rel, "reason": NEW_MOD_REJECT[1]})
        else:
            rejected.append({"target": rel, "reason": "missing_capability_manifest"})
        continue
    try:
        m = json.loads(man.read_text())
    except Exception as e:
        rejected.append({"target": rel, "reason": f"invalid_manifest: {e}"})
        continue
    if m.get("immutable") is not False:
        rejected.append({"target": rel, "reason": "manifest_immutable_not_false"})
        continue
    if m.get("schema") != 1:
        rejected.append({"target": rel, "reason": "manifest_schema_not_1"})
        continue
    accepted.append({"target": rel, "module": m.get("module"), "manifest": str(man.relative_to(suite))})

ok = len(rejected) == 0 and len(accepted) > 0
if new_module and NEW_MOD_REJECT is not None and ok:
    # Belt-and-braces: a rejected proposed manifest must fail the gate even if
    # some other target slipped through an accept path above.
    ok = False
    rejected.append({"target": NEW_MOD_REJECT[0], "reason": NEW_MOD_REJECT[1]})
if len(targets) == 0:
    ok = False
    rejected.append({"target": None, "reason": "no_targets"})

out = {
    "ok": ok,
    "accepted": accepted,
    "rejected": rejected,
    "module": module or None,
}
print(json.dumps(out, indent=2))
sys.exit(0 if ok else 1)
PY
