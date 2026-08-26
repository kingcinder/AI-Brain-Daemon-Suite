#!/usr/bin/env python3
"""Shared path-safety helpers for the self-mod pipeline.

Single source of truth for:
  * proposal-target path normalization (norm)
  * immutable-core matching (is_immutable / resolved_is_immutable)
  * suite-escape resolution (resolve_in_suite)

Used by check-target.sh (the gate) and apply-patch.sh (the writer) so the
two can never disagree about what a path means — the divergence that once
let apply-patch's `lstrip("./")` silently rewrite traversal attempts into
in-suite paths instead of rejecting them.

Both callers run their embedded Python with PYTHONPATH pointed at this
directory (`PYTHONPATH="$(cd "$(dirname "$0")" && pwd)" python3 - ...`)
and `import pathguard`.
"""

import fnmatch
from pathlib import Path


def norm(p: str) -> str:
    """Normalize a proposal target to a suite-relative POSIX path.

    Deliberately NOT lstrip("./"): stripping every leading '.' and '/'
    character would turn "../../etc/passwd" into "etc/passwd", silently
    rewriting traversal attempts into an in-suite path instead of letting the
    suite-escape check reject them. Only leading './' prefixes and leading
    '/' are stripped; leading '..' components are NEVER stripped (they must
    stay visible so the resolve()-based containment check can reject them).
    Idempotent: applying norm twice yields the same result, so callers that
    pre-normalize and then pass the result through resolve_in_suite (which
    normalizes again) stay consistent.
    """
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    # Leading '/' is deliberately NOT stripped: an absolute path must stay
    # absolute so the suite-escape check ((suite / rel).relative_to(suite))
    # rejects it instead of silently relocating it inside the suite.
    return p


def load_immutable(path: str | Path) -> list[str]:
    """Read a non-comment, non-blank pattern list from an immutable-paths file."""
    out: list[str] = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


def is_immutable(rel: str, immutable: list[str]) -> bool:
    """Immutable-core match for a normalized rel path against pattern list.

    Patterns are globs (fnmatch). A pattern ending in '/*' also matches the
    bare directory (e.g. 'core/self-mod/*' matches 'core/self-mod/foo' and
    'core/self-mod'). decide.sh has a hard rule beyond the list.
    """
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


def resolved_is_immutable(suite: Path, abs_path: Path, immutable: list[str]) -> bool:
    """Immutable check against a RESOLVED absolute path (symlink target).

    resolve() follows symlinks, so writing through a symlink that points at
    an immutable file must be refused even though the user-supplied rel path
    looked benign.
    """
    try:
        rel = abs_path.relative_to(suite.resolve())
    except ValueError:
        return False
    return is_immutable(str(rel), immutable)


def resolve_in_suite(suite: Path, rel: str) -> Path | None:
    """Resolve rel against suite; return the resolved absolute Path, or None
    if the path escapes the suite (.. beyond root, an absolute path, or a
    symlink out). Self-contained: the suite is canonicalized here, so a
    caller passing an unresolved or symlinked suite cannot skew the
    containment comparison."""
    rel = norm(rel)
    suite = suite.resolve()
    try:
        abs_path = (suite / rel).resolve()
        abs_path.relative_to(suite)
        return abs_path
    except ValueError:
        return None


def patch_targets(diff: str) -> list[str]:
    """Extract the file paths a unified diff will touch (the `+++`/`---`
    headers), normalized the way `patch -p1` actually resolves them: strip
    exactly ONE leading path component (git's `a/`/`b/` prefixes are just
    that first component), and /dev/null (new-file / deletion placeholders)
    is skipped.

    Stripping the single leading component is what `patch -p1` does to every
    header — a git-style `a/core/foo` lands on `core/foo`, and a non-git
    header like `x/core/concurrency/semaphore.sh` would land on
    `core/concurrency/semaphore.sh`. Gating only the literal header path
    would let the non-git spelling sneak an immutable/out-of-suite write
    past the gate while patch happily writes the stripped target."""
    import re

    out = []
    for line in diff.splitlines():
        m = re.match(r"^[+-]{3}\s+(\S+)", line)
        if not m:
            continue
        p = m.group(1)
        if p in ("/dev/null",):
            continue
        # `patch -p1`: strip one leading component (git a/ b/ included).
        p1 = p.split("/", 1)[1] if "/" in p else p
        if not p1:
            # Header like "--- a/" — no real filename; patch itself rejects
            # empty names, so skip it rather than resolve the suite root.
            continue
        out.append(p1)
    return out
