#!/usr/bin/env python3
"""codypc adapter — the existing substrate, behind the contract.

Preserves the current path bit-for-bit; nothing here replaces
``deep-brain-kernel.py``, the spawn provider, or any skill. The contract
gives the existing machinery a typed boundary so job logic can be written
portably.

  * :class:`CodypcMemoryStore` — ``$WORKSPACE``-rooted files, atomic
    tmp+rename writes, traversal rejection mirroring
    ``core/self-mod/pathguard.py``.
  * :class:`CodypcScheduler` — persists :class:`JobSpec`\\ s to
    ``$WORKSPACE/memory/runtime-contract/jobs.json``; :meth:`to_kernel_job`
    converts a spec to the ``deep-brain-kernel.py`` ``Job(...)`` entry shape
    for future wiring (the kernel itself is untouched by this branch).
  * :class:`CodypcMind` — ``invoke()`` execs
    ``bash core/spawn/spawn-provider.sh --task <prompt>`` with the same env
    the kernel sets (``WORKSPACE``, ``SPAWN_PROVIDER`` default ``agentloop``,
    ``AGENT_SESSION_ID``). Any failure raises :class:`MindUnavailable`.
  * :class:`CodypcRuntime` — wires the above; provenance appends to
    ``$WORKSPACE/memory/provenance/events.jsonl`` (same path
    ``log-provenance.sh`` uses), best-effort, never raising.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path

from ..contract import (
    JobSpec, MemoryStore, MemoryViolation, Mind, MindUnavailable, Runtime,
    Scheduler, ScheduleError, utc_now_iso,
)

log = logging.getLogger("runtime.codypc")


def _suite_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


class CodypcMemoryStore(MemoryStore):
    def __init__(self, workspace: Path | str | None = None):
        ws = workspace or os.environ.get("WORKSPACE",
                                         str(Path.home() / ".hermes" / "workspace"))
        self.root = Path(ws).resolve()

    def _resolve(self, relpath: str) -> Path:
        # Traversal safety (contract §1): reject, never rewrite.
        if not relpath or relpath.startswith("/") or relpath.startswith("~"):
            raise MemoryViolation(f"absolute path rejected: {relpath!r}")
        candidate = (self.root / relpath).resolve()
        try:
            candidate.relative_to(self.root)
        except ValueError:
            raise MemoryViolation(f"path escapes store root: {relpath!r}")
        return candidate

    def read(self, relpath: str) -> str | None:
        p = self._resolve(relpath)
        try:
            return p.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None

    def write(self, relpath: str, content: str) -> None:
        p = self._resolve(relpath)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + f".tmp-{os.getpid()}")
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, p)  # atomic on POSIX

    def append_text(self, relpath: str, text: str) -> None:
        p = self._resolve(relpath)
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(text)

    def exists(self, relpath: str) -> bool:
        return self._resolve(relpath).exists()

    def list(self, prefix: str) -> list[str]:
        base = self._resolve(prefix)
        if not base.is_dir():
            return []
        return sorted(str(p.relative_to(self.root))
                      for p in base.rglob("*") if p.is_file())


class CodypcScheduler(Scheduler):
    """Job registry persisted under the workspace. The kernel's own JOBS
    table is untouched; to_kernel_job() renders the equivalent entry for
    future wiring."""
    STORE_REL = "memory/runtime-contract/jobs.json"

    def __init__(self, memory: CodypcMemoryStore):
        self.memory = memory

    def _load(self) -> dict:
        raw = self.memory.read(self.STORE_REL)
        if not raw:
            return {}
        try:
            data = json.loads(raw)
            return data if isinstance(data, dict) else {}
        except ValueError:
            return {}

    def _save(self, data: dict) -> None:
        self.memory.write(self.STORE_REL, json.dumps(data, indent=2) + "\n")

    def schedule(self, spec: JobSpec) -> None:
        spec.validate()
        data = self._load()
        data[spec.id] = {
            "id": spec.id, "kind": spec.kind, "days": spec.days,
            "hours": spec.hours, "minutes": spec.minutes,
            "task": spec.task, "max_steps": spec.max_steps,
        }
        try:
            self._save(data)
        except OSError as e:
            raise ScheduleError(str(e))

    def unschedule(self, job_id: str) -> None:
        data = self._load()
        if job_id in data:
            del data[job_id]
            self._save(data)

    def list_jobs(self) -> list[JobSpec]:
        return [JobSpec(**v) for v in self._load().values()]

    @staticmethod
    def to_kernel_job(spec: JobSpec) -> str:
        """Render the deep-brain-kernel.py Job(...) entry for this spec."""
        return (f'Job("{spec.id}", "{spec.kind}", "{spec.hours}", '
                f'"{spec.minutes}",\n'
                f'    """{spec.task}""",\n'
                f'    days="{spec.days}", spawn_max_steps={spec.max_steps}),')


class CodypcMind(Mind):
    """Mind invocation through the existing spawn-provider shim — the same
    exec boundary the kernel uses (pidfd tracking, timeout, provider
    selection all live on the other side of it)."""

    def __init__(self, suite_root: Path | str | None = None,
                 workspace: Path | str | None = None,
                 provider: str | None = None):
        self.suite_root = Path(suite_root or _suite_root()).resolve()
        self.workspace = str(workspace or os.environ.get(
            "WORKSPACE", str(Path.home() / ".hermes" / "workspace")))
        self.provider = (provider or os.environ.get("SPAWN_PROVIDER",
                                                    "agentloop")).strip().lower()
        self.shim = self.suite_root / "core" / "spawn" / "spawn-provider.sh"

    def invoke(self, prompt: str, *, system: str = "",
               max_steps: int = 8, timeout_s: float = 900) -> str:
        if not self.shim.is_file():
            raise MindUnavailable(f"spawn-provider shim missing at {self.shim}")
        env = os.environ.copy()
        env["WORKSPACE"] = self.workspace
        env["SPAWN_PROVIDER"] = self.provider
        env["AGENT_MAX_STEPS"] = str(max_steps)
        # NOTE: system prompt is folded into the task text — the shim's
        # agentloop/local paths take a single task string.
        task = f"{system}\n\n{prompt}" if system else prompt
        try:
            proc = subprocess.run(
                ["bash", str(self.shim), "--task", task],
                env=env, capture_output=True, text=True,
                timeout=timeout_s)
        except subprocess.TimeoutExpired as e:
            raise MindUnavailable(
                f"spawn-provider timed out after {timeout_s:.0f}s") from e
        except OSError as e:
            raise MindUnavailable(f"spawn-provider exec failed: {e}") from e
        if proc.returncode != 0:
            tail = (proc.stdout + proc.stderr)[-2000:]
            raise MindUnavailable(
                f"spawn-provider exited {proc.returncode}: {tail[-500:]}")
        out = proc.stdout.strip()
        if not out:
            raise MindUnavailable("spawn-provider returned empty output")
        return out


class CodypcRuntime(Runtime):
    name = "codypc"

    def __init__(self, workspace: Path | str | None = None,
                 suite_root: Path | str | None = None,
                 provider: str | None = None):
        self.memory = CodypcMemoryStore(workspace)
        self.scheduler = CodypcScheduler(self.memory)
        self.mind: Mind | None = CodypcMind(suite_root, workspace, provider)
        self._suite_root = Path(suite_root or _suite_root()).resolve()
        self._workspace = self.memory.root

    def asset(self, relpath: str) -> str | None:
        p = (self._suite_root / relpath).resolve()
        try:
            p.relative_to(self._suite_root)
        except ValueError:
            return None
        try:
            return p.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None

    def log(self, level: str, message: str, **fields) -> None:
        getattr(log, level, log.info)("%s %s", message, fields or "")

    def provenance(self, event: str, detail: dict) -> None:
        # S7: best-effort, never raises.
        try:
            record = {"ts": utc_now_iso(), "event": event,
                      "actor": "runtime-contract", "detail": detail}
            self.memory.append_jsonl("memory/provenance/events.jsonl", record)
        except Exception as e:  # noqa: BLE001 — provenance must not break callers
            log.warning("provenance append failed: %s", e)
