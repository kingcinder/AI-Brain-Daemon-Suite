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
elif target_arg:
    targets = [target_arg]

def norm(p: str) -> str:
    p = p.replace("\\", "/").lstrip("./")
    # reject absolute escapes outside suite
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
    man = find_manifest(module, rel)
    if man is None:
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
