#!/usr/bin/env python3
"""Apply and rollback for Juno self-modification proposals.

Every apply snapshots first. Rollback restores byte-for-byte and proves it
by hash — rollback is tested, not just written (see
core/runtime/tests/test_self_mod.py).

For virtual (cron) targets the adapter cannot write directly: apply emits
an executable plan document and returns status "plan_issued". The plan is
honest about the seam — it tells the agent exactly what to run, including
recording the prior state first so rollback stays possible.
"""

from __future__ import annotations

import hashlib
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from .proposal import Proposal, utc_now_iso


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class BackupRecord:
    proposal_id: str
    backed_up_at: str
    backup_dir: str
    files: dict = field(default_factory=dict)  # str(path) -> sha256


@dataclass
class ApplyResult:
    ok: bool
    backup: BackupRecord | None = None
    plan_path: str | None = None   # set for virtual (cron) targets
    detail: str = ""


@dataclass
class RollbackResult:
    ok: bool
    byte_identical: bool = False
    detail: str = ""


class Applier:
    """Snapshot/apply/rollback. Needs the same target resolver as the
    verifier, plus a plan emitter for virtual targets."""

    def __init__(self, resolve_target, emit_plan=None,
                 backup_root: Path | str | None = None):
        """
        resolve_target(scope, target) -> pathlib.Path | None.
        emit_plan(proposal, context) -> str (path of the written plan doc).
        backup_root: where snapshots live (tests point this at temp dirs).
        """
        self._resolve_target = resolve_target
        self._emit_plan = emit_plan
        self._backup_root = Path(backup_root) if backup_root else None

    # -- snapshot -----------------------------------------------------------
    def snapshot(self, proposal: Proposal) -> BackupRecord:
        path = self._resolve_target(proposal.scope, proposal.target)
        if path is None or not path.is_file():
            raise ValueError(
                f"cannot snapshot non-file target "
                f"{proposal.scope}:{proposal.target}")
        root = self._backup_root or Path.home() / "self_mod_backups"
        backup_dir = root / proposal.id
        backup_dir.mkdir(parents=True, exist_ok=True)
        digest = sha256_file(path)
        dest = backup_dir / (path.name + ".bak")
        shutil.copy2(path, dest)
        if sha256_file(dest) != digest:
            raise RuntimeError("backup copy failed hash check — aborting")
        return BackupRecord(proposal_id=proposal.id,
                            backed_up_at=utc_now_iso(),
                            backup_dir=str(backup_dir),
                            files={str(path): digest})

    # -- apply ---------------------------------------------------------------
    def apply(self, proposal: Proposal) -> ApplyResult:
        """Apply a verified+approved proposal. File targets: snapshot then
        write. Virtual (cron) targets: snapshot is impossible — emit the
        executable plan instead and return plan_issued semantics via
        plan_path (the pipeline sets the status)."""
        if proposal.scope == "cron":
            if self._emit_plan is None:
                raise ValueError("no plan emitter for virtual targets")
            plan_path = self._emit_plan(proposal, {})
            return ApplyResult(ok=True, plan_path=plan_path,
                               detail="plan issued; agent must execute it")

        if proposal.new_content is None:
            raise ValueError("new_content is required for file targets")
        backup = self.snapshot(proposal)
        path = self._resolve_target(proposal.scope, proposal.target)
        # Atomic write: tmp + rename, same as the memory store.
        tmp = path.with_name(path.name + f".selfmod-{proposal.id}.tmp")
        tmp.write_text(proposal.new_content, encoding="utf-8")
        tmp.replace(path)
        return ApplyResult(ok=True, backup=backup,
                           detail=f"applied to {path}")

    # -- rollback -------------------------------------------------------------
    def rollback(self, backup: BackupRecord) -> RollbackResult:
        """Restore every snapshotted file byte-for-byte and prove it."""
        if not backup.files:
            return RollbackResult(ok=False, detail="empty backup record")
        backup_dir = Path(backup.backup_dir)
        for path_str, digest in backup.files.items():
            path = Path(path_str)
            src = backup_dir / (path.name + ".bak")
            if not src.is_file():
                return RollbackResult(
                    ok=False,
                    detail=f"backup file missing: {src}")
            shutil.copy2(src, path)
            restored = sha256_file(path)
            if restored != digest:
                return RollbackResult(
                    ok=False,
                    detail=f"hash mismatch after restore: {path} "
                           f"(got {restored[:12]}, want {digest[:12]})")
        return RollbackResult(ok=True, byte_identical=True,
                              detail=f"restored {len(backup.files)} file(s), "
                                     "hashes match pre-apply state")
