#!/bin/bash
# validate-manifest.sh — Validate Capability Registry manifests (Phase 2).
#
# Usage:
#   validate-manifest.sh <manifest.json>
#   validate-manifest.sh --all          # all skills/*/capability-manifest.json
# Exit 0 if all valid.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$ROOT/core/capability-registry.schema.json"

validate_one() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "FAIL: not found: $f" >&2
    return 1
  fi
  python3 - "$f" "$SCHEMA" <<'PY'
import json, sys
path, schema_path = sys.argv[1], sys.argv[2]
m = json.loads(open(path).read())
required = ["schema","module","version","capabilities","inputs","outputs","side_effects","dependencies","tests","immutable"]
errs = []
for k in required:
    if k not in m:
        errs.append(f"missing field {k}")
if m.get("schema") != 1:
    errs.append("schema must be 1")
if m.get("immutable") is not False:
    errs.append("immutable must be false (Immutable Core modules must not carry manifests)")
if not isinstance(m.get("tests"), list) or len(m.get("tests") or []) < 1:
    errs.append("tests must have minItems 1")
side = m.get("side_effects") or []
allowed_side = {"writes_shared_state","spawns_inference","modifies_locks","network_io","filesystem_write","none"}
for s in side:
    if s not in allowed_side:
        errs.append(f"invalid side_effect: {s}")
if not side:
    errs.append("side_effects empty — use ['none'] if pure")
if side and "none" not in side and len(side)==0:
    errs.append("none required when empty")
# version semver-ish
import re
if not re.match(r"^\d+\.\d+\.\d+$", str(m.get("version",""))):
    errs.append("version must match N.N.N")
for item in m.get("inputs") or []:
    for k in ("name","type","source"):
        if k not in item:
            errs.append(f"input missing {k}")
    if item.get("type") not in ("state_file","inference_call","scalar","event"):
        errs.append(f"bad input type {item.get('type')}")
for item in m.get("outputs") or []:
    for k in ("name","type","target"):
        if k not in item:
            errs.append(f"output missing {k}")
    if item.get("type") not in ("state_write","log_entry","scalar","event"):
        errs.append(f"bad output type {item.get('type')}")
if errs:
    print(f"FAIL: {path}")
    for e in errs:
        print(f"  - {e}")
    sys.exit(1)
print(f"PASS: {path} (module={m['module']} v{m['version']})")
PY
}

if [ "${1:-}" = "--all" ]; then
  fail=0
  for f in "$ROOT"/skills/*/capability-manifest.json; do
    validate_one "$f" || fail=1
  done
  # Optional core peripheral manifests (e.g. executive-function)
  if [ -f "$ROOT/core/executive/capability-manifest.json" ]; then
    validate_one "$ROOT/core/executive/capability-manifest.json" || fail=1
  fi
  exit $fail
fi

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <manifest.json> | --all" >&2
  exit 2
fi
validate_one "$1"
