#!/usr/bin/env python3
"""juno adapter — the AI-assistant agent runtime, behind the contract.

HONEST CAPABILITY MAPPING. The agent runtime exposes: file read/write,
shell exec, cron-job management (via the agent's cron tool — NOT callable
from adapter code), and markdown memory files (``~/memory/YYYY-MM-DD.md``
daily logs). The adapter maps onto exactly those, and nothing else:

  * :class:`JunoMemoryStore` — file-backed, rooted at a configurable dir,
    1:1 suite-relative mapping with atomic tmp+rename writes and the same
    traversal rejection as the codypc store. Content stays markdown with
    dated ``##`` sections (the job logic already formats entries that way),
    so the files remain consumable by the runtime's memory indexer.
    Production wiring (the agent's real ``~/memory`` tree) is performed by
    the agent's scheduled-task body; the adapter never pretends to reach
    the agent's tools.
  * :class:`JunoScheduler` — ``schedule()`` writes a **schedule-request
    document** (``{action, id, schedule{kind,dow,time,timezone}, title,
    body}``) under ``{root}/schedule-requests/``. Installing it is
    agent-mediated (the cron tool); adapter code cannot call agent tools, so
    the adapter emits the request instead of pretending to install it.
    ``unschedule()`` writes a removal request.
  * ``mind`` is ``None`` — the embedded-mind pattern (contract §3). On this
    runtime the weekly-reflection flow is: cron fires → agent runs
    ``build_prompt()`` → agent reflects → agent calls ``complete(text)``.
    ``ContractJob.run()`` raises :class:`ContractError` directing the caller
    to that split flow.

Nothing here is aspirational: every method is implemented against file I/O
and JSON documents only.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path

from ..contract import (
    ContractError, JobSpec, MemoryStore, MemoryViolation, Runtime,
    ScheduleError, Scheduler, ScriptResult, utc_now_iso,
)
from ..self_mod.juno_capability import JunoSelfMod

log = logging.getLogger("runtime.juno")

class JunoMemoryStore(MemoryStore):
    """Markdown-native memory. ``root`` is the adapter's workspace dir
    (use a sandbox for demos; production wiring targets the agent's real
    memory tree via the scheduled-task body). Suite-relative paths map 1:1
    under the root; the weekly-reflection job writes dated ``##`` markdown
    sections, which the runtime's memory indexer consumes."""

    def __init__(self, root: Path | str | None = None):
        self.root = Path(root or Path.home() / ".juno-brain").resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    # -- path resolution --------------------------------------------------
    def _resolve(self, relpath: str) -> Path:
        # Traversal safety (contract §1): reject, never rewrite.
        norm = relpath.replace(os.sep, "/").lstrip("/")
        if not norm or norm.startswith(("/", "~")) or ".." in norm.split("/"):
            raise MemoryViolation(f"path rejected: {relpath!r}")
        target = (self.root / norm).resolve()
        try:
            target.relative_to(self.root)
        except ValueError:
            raise MemoryViolation(f"path escapes store root: {relpath!r}")
        return target

    # -- MemoryStore --------------------------------------------------------
    def read(self, relpath: str) -> str | None:
        try:
            return self._resolve(relpath).read_text(encoding="utf-8")
        except FileNotFoundError:
            return None

    def write(self, relpath: str, content: str) -> None:
        target = self._resolve(relpath)
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + f".tmp-{os.getpid()}")
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, target)  # atomic on POSIX

    def append_text(self, relpath: str, text: str) -> None:
        target = self._resolve(relpath)
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "a", encoding="utf-8") as f:
            f.write(text)

    def exists(self, relpath: str) -> bool:
        return self._resolve(relpath).exists()

    def list(self, prefix: str) -> list[str]:
        base = self._resolve(prefix)
        if not base.is_dir():
            return []
        return sorted(str(p.relative_to(self.root))
                      for p in base.rglob("*") if p.is_file())


class JunoScheduler(Scheduler):
    """Emits schedule-request documents. Installation is agent-mediated via
    the agent's cron tool — this class documents the request; it does not
    (and cannot) install it."""

    REQUESTS_DIR = "schedule-requests"

    def __init__(self, root: Path | str):
        self.root = Path(root).resolve()

    def _requests_dir(self) -> Path:
        d = self.root / self.REQUESTS_DIR
        d.mkdir(parents=True, exist_ok=True)
        return d

    def _spec_to_request(self, spec: JobSpec) -> dict:
        # Suite slot (UTC) → weekly cron shape. Local-time conversion needs
        # an explicit timezone, which the agent supplies at install time.
        return {
            "action": "cron.add",
            "id": spec.id,
            "title": "Weekly self-reflection (recursive self improvement)",
            "schedule": {
                "kind": "weekly",
                "dow": ["Sun"],
                "suite_slot_utc": {"days": spec.days, "hours": spec.hours,
                                   "minutes": spec.minutes},
                "note": ("Install in the user's timezone; the suite slot is "
                         "Sunday 02:44 UTC. Timezone conversion is the "
                         "installing agent's responsibility."),
            },
            "mode": "task",
            "body": (
                "Recursive self improvement — weekly honest self-reflection.\n\n"
                "1. Build the prompt: instantiate WeeklyReflectionJob from "
                "core/runtime/jobs/weekly_reflection.py against the Juno "
                "runtime adapter and call build_prompt().\n"
                "2. Reflect: answer honestly (how you changed this week, "
                "opinion shifts, relationship evolution, patterns, pride, "
                "what to work on). Be honest, not performative.\n"
                "3. Persist: call complete(reflection_text). The adapter "
                "writes the Juno-runtime memory log and provenance.\n"
                "4. Surface to the user ONLY what is genuinely worth their "
                "attention; otherwise stay silent."
            ),
            "requested_at": utc_now_iso(),
        }

    def schedule(self, spec: JobSpec) -> None:
        spec.validate()
        path = self._requests_dir() / f"{spec.id}.json"
        try:
            path.write_text(json.dumps(self._spec_to_request(spec), indent=2)
                            + "\n", encoding="utf-8")
        except OSError as e:
            raise ScheduleError(str(e))

    def unschedule(self, job_id: str) -> None:
        path = self._requests_dir() / f"{job_id}.json"
        if path.exists():
            path.unlink()
        # A removal request, so the agent knows to drop the installed cron.
        (self._requests_dir() / f"{job_id}.remove-request.json").write_text(
            json.dumps({"action": "cron.remove", "id": job_id,
                        "requested_at": utc_now_iso()}, indent=2) + "\n",
            encoding="utf-8")

    def list_jobs(self) -> list[JobSpec]:
        # Requests are pending until the agent installs them; report the
        # requested specs (not installed crons — the adapter cannot see those).
        specs = []
        for path in sorted(self._requests_dir().glob("*.json")):
            if path.name.endswith(".remove-request.json"):
                continue
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                continue
            slot = doc["schedule"]["suite_slot_utc"]
            specs.append(JobSpec(id=doc["id"], kind="spawn",
                                 days=slot["days"], hours=slot["hours"],
                                 minutes=slot["minutes"]))
        return specs


class JunoRuntime(Runtime):
    name = "juno"

    def __init__(self, root: Path | str | None = None,
                 suite_root: Path | str | None = None,
                 skills_root: Path | str | None = None,
                 memory_root: Path | str | None = None):
        self._root = Path(root or Path.home() / ".juno-brain").resolve()
        self.memory = JunoMemoryStore(self._root)
        self.scheduler = JunoScheduler(self._root)
        self.mind = None  # embedded-mind pattern: the agent IS the mind
        self._suite_root = Path(
            suite_root or Path(__file__).resolve().parent.parent.parent
        ).resolve()
        # Self-mod capability: the pipeline's hands. Operates on real
        # targets (skills dir, memory dir); cron targets become executable
        # plan documents — the adapter never pretends to call agent tools.
        self.self_mod = JunoSelfMod(
            self,
            skills_root=skills_root,
            memory_root=(memory_root if memory_root is not None
                         else self._root / "memory"),
            plans_dir=self._root / "self-mod-plans",
            backup_root=self._root / "self-mod-backups",
        )

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
            self.memory.append_jsonl("provenance-log.jsonl", record)
        except Exception as e:  # noqa: BLE001 — provenance must not break callers
            log.warning("provenance append failed: %s", e)

    def run_script(self, relpath: str, args: list[str] | None = None,
                   timeout_s: float = 300) -> ScriptResult:
        """Direct-kind job execution on the Juno runtime.

        HONESTY NOTE: this works only where the agent runtime actually has a
        POSIX shell — this environment does (exec/bash), so the adapter
        probes for it and runs suite scripts the same way codypc does, with
        WORKSPACE pointed at the adapter root. Where no shell exists the
        adapter raises ContractError and the scheduled-task body must run
        the script agent-mediated (the agent's exec tool) instead. Scripts
        are bash with coreutil deps (decay.sh also shells to python3); the
        probe covers bash only — a script whose own shebang/deps are
        missing fails loudly with its own stderr, never silently.
        """
        import shutil
        import subprocess
        if shutil.which("bash") is None:
            raise ContractError(
                "no bash on this runtime: direct-kind script execution is "
                "agent-mediated here — run the script via the agent's exec "
                "tool in the scheduled-task body, then complete() manually")
        script = (self._suite_root / relpath).resolve()
        try:
            script.relative_to(self._suite_root)
        except ValueError:
            raise ContractError(f"script escapes suite root: {relpath!r}")
        if not script.is_file():
            raise ContractError(f"script not found: {script}")
        env = os.environ.copy()
        env["WORKSPACE"] = str(self._root)
        try:
            proc = subprocess.run(
                ["bash", str(script), *(args or [])],
                env=env, capture_output=True, text=True,
                timeout=timeout_s,
            )
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or "") + (e.stderr or "")
            return ScriptResult(returncode=-1, output=out[-20000:],
                                timed_out=True)
        out = (proc.stdout or "") + (proc.stderr or "")
        return ScriptResult(returncode=proc.returncode,
                            output=out[-20000:], timed_out=False)
