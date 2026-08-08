#!/bin/bash
# apply-patch.sh — Apply a proposal's file payload into a target tree (suite root).
#
# Proposal fields:
#   target_paths: [rel path, ...]  (first is primary)
#   content: full new file body (UTF-8 text)
#   OR content_b64: base64 body
#   OR files: { "rel/path": "file body", ... }  (M6: per-file content — needed
#      when a proposal creates a brand-new module: manifest + scripts + tests
#      each carry distinct bodies)
#   OR patch_unified: unified diff (applied with patch -p1)
#
# Usage:
#   apply-patch.sh --suite-root PATH --proposal PATH.json [--dry-run]
#
# Does not check immutable rules (caller must run check-target first).

set -euo pipefail

SUITE_ROOT=""
PROPOSAL=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --proposal) PROPOSAL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

[ -n "$SUITE_ROOT" ] && [ -f "$PROPOSAL" ] || {
  echo "Usage: $0 --suite-root PATH --proposal PATH.json" >&2
  exit 2
}

python3 - "$SUITE_ROOT" "$PROPOSAL" "$DRY" <<'PY'
import json, sys, base64, subprocess
from pathlib import Path

suite = Path(sys.argv[1]).resolve()
prop = json.loads(Path(sys.argv[2]).read_text())
dry = sys.argv[3] == "1"

targets = prop.get("target_paths") or prop.get("targets") or []
if prop.get("target"):
    targets = [prop["target"]] + list(targets)
if not targets:
    print(json.dumps({"ok": False, "error": "no targets"}))
    sys.exit(1)

applied = []
if prop.get("patch_unified"):
    patch_text = prop["patch_unified"]
    if dry:
        print(json.dumps({"ok": True, "dry_run": True, "mode": "unified_diff", "targets": targets}))
        sys.exit(0)
    p = subprocess.run(
        ["patch", "-p1", "--forward", "--batch"],
        input=patch_text,
        text=True,
        cwd=str(suite),
        capture_output=True,
    )
    if p.returncode != 0:
        print(json.dumps({"ok": False, "error": "patch_failed", "stderr": p.stderr[-2000:]}))
        sys.exit(1)
    print(json.dumps({"ok": True, "mode": "unified_diff", "targets": targets}))
    sys.exit(0)

files_map = prop.get("files")
content = prop.get("content")
if content is None and prop.get("content_b64"):
    content = base64.b64decode(prop["content_b64"]).decode("utf-8")
if content is None and not isinstance(files_map, dict):
    print(json.dumps({"ok": False, "error": "no content, files, or patch_unified"}))
    sys.exit(1)


def _write(rel, body):
    """Write one file body to `rel` inside the suite, suite-escape guarded."""
    rel = rel.replace("\\", "/").lstrip("./")
    dest = (suite / rel).resolve()
    try:
        dest.relative_to(suite)
    except ValueError:
        print(json.dumps({"ok": False, "error": f"outside suite: {rel}"}))
        sys.exit(1)
    if dry:
        applied.append(rel)
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(body if body.endswith("\n") else body + "\n")
    applied.append(rel)


if isinstance(files_map, dict) and files_map:
    # M6: per-file map — write each declared path with its own body. The
    # `targets` list still names the primary/checked paths (manifest first).
    for rel, body in files_map.items():
        _write(str(rel), str(body))
    print(json.dumps({"ok": True, "mode": "file_write_files", "applied": applied, "dry_run": dry}))
    sys.exit(0)

# Single-content write to each target (typically one primary file)
for rel in targets:
    _write(rel, content)

print(json.dumps({"ok": True, "mode": "file_write", "applied": applied, "dry_run": dry}))
PY
