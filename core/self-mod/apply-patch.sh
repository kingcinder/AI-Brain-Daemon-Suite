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
# Caller must run check-target first for the authoritative immutable/
# manifest gate. This script additionally refuses (defense-in-depth, never
# skippable):
#   * any write that resolves outside the suite (path traversal, incl. via
#     symlinks), and
#   * any write to an Immutable Core path (from immutable-paths.list),
#     including through a symlink that resolves onto an immutable file, and
#   * patch_unified diffs whose headers name a file outside the suite or an
#     immutable path.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# PYTHONPATH carries this directory so the embedded Python can import the
# shared path-safety module — the same one check-target.sh uses, so the two
# can never disagree about what a path means.
PYTHONPATH="$SELF_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SUITE_ROOT" "$PROPOSAL" "$DRY" "$SELF_DIR" <<'PY'
import json, sys, base64, subprocess
from pathlib import Path

import pathguard

suite = Path(sys.argv[1]).resolve()
prop = json.loads(Path(sys.argv[2]).read_text())
dry = sys.argv[3] == "1"
self_dir = Path(sys.argv[4])

# Defense-in-depth immutable list: prefer the suite-relative list (present in
# the live tree and in every sandbox copy), fall back to the script's own.
# FAIL CLOSED: if no list is found anywhere, refuse to write at all — an
# absent immutable-paths.list must never degrade to "nothing is immutable".
IMMUTABLE = []
IMMUTABLE_SRC = None
for cand in (suite / "core" / "self-mod" / "immutable-paths.list",
             self_dir / "immutable-paths.list"):
    if cand.is_file():
        IMMUTABLE_SRC = cand
        IMMUTABLE = pathguard.load_immutable(cand)
        break
if IMMUTABLE_SRC is None:
    print(json.dumps({"ok": False, "error": "immutable-paths.list not found — refusing to write (fail closed)"}))
    sys.exit(1)

targets = prop.get("target_paths") or prop.get("targets") or []
if prop.get("target"):
    targets = [prop["target"]] + list(targets)
if not targets:
    print(json.dumps({"ok": False, "error": "no targets"}))
    sys.exit(1)

applied = []
if prop.get("patch_unified"):
    patch_text = prop["patch_unified"]
    # Gate the diff BEFORE applying: every header path must resolve inside the
    # suite and must not be immutable. This closes the patch_unified bypass
    # (patch -p1 applies whatever the diff says, ignoring target_paths).
    bad = []
    for pt in pathguard.patch_targets(patch_text):
        if pathguard.resolve_in_suite(suite, pt) is None:
            bad.append({"target": pt, "reason": "outside_suite_root"})
        elif pathguard.is_immutable(pt, IMMUTABLE):
            bad.append({"target": pt, "reason": "immutable_core"})
    if bad:
        print(json.dumps({"ok": False, "error": "patch_unified_target_rejected", "rejected": bad}))
        sys.exit(1)
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
    """Write one file body to `rel` inside the suite. Refuses anything that
    resolves outside the suite or onto an Immutable Core path (checked on the
    RESOLVED path, so a symlink pointing at an immutable file is refused)."""
    rel = pathguard.norm(rel)
    dest = (suite / rel).resolve()
    try:
        dest.relative_to(suite)
    except ValueError:
        print(json.dumps({"ok": False, "error": f"outside suite: {rel}"}))
        sys.exit(1)
    # Immutable check on the resolved path (symlink target), plus the literal
    # rel path — both must be safe.
    if pathguard.resolved_is_immutable(suite, dest, IMMUTABLE) or pathguard.is_immutable(rel, IMMUTABLE):
        print(json.dumps({"ok": False, "error": f"immutable core: {rel}"}))
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
