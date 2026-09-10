#!/usr/bin/env python3
"""Runtime contract — substrate-independent interface for the AI Brain Suite.

Reference implementation of ``core/runtime/RUNTIME_CONTRACT.md`` (v0.1.0).

A *runtime adapter* implements :class:`Runtime` for one substrate (a Linux
host, an AI-assistant agent runtime, ...). Job logic (:class:`ContractJob`)
is written once, against this contract, and runs on any adapter.

Safety kernel (S1..S10 in RUNTIME_CONTRACT.md) is carried here as concrete
helpers: :meth:`Runtime.check_immutable` and :meth:`Runtime.autonomy_mode`
implement S1/S2; the spawn-audit requirement (S3) is implemented in
:meth:`ContractJob.run`.

Stdlib only. Import-safe: no side effects at module level.
"""

from __future__ import annotations

import abc
import fnmatch
import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

CONTRACT_VERSION = "0.1.0"


# --------------------------------------------------------------------------
# Errors — failures are typed, never silent.
# --------------------------------------------------------------------------

class ContractError(Exception):
    """Base for all runtime-contract errors."""


class MindUnavailable(ContractError):
    """The substrate's mind could not be invoked (no endpoint, timeout,
    malformed reply). Raised, never swallowed — a job that cannot think
    must fail loudly, not record a silent success."""


class MemoryViolation(ContractError):
    """A memory path escaped the store root (traversal, absolute path,
    symlink escape). Rejected, never silently rewritten."""


class ScheduleError(ContractError):
    """The scheduler could not register/remove the job."""


# --------------------------------------------------------------------------
# Value types
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class JobSpec:
    """Portable job descriptor. The days/hours/minutes spec language is the
    suite's existing one (deep-brain-kernel._spec_matches): comma-separated
    ints or "*"; days uses Python datetime.weekday() (0=Monday..6=Sunday).
    Times are UTC unless the adapter documents otherwise."""
    id: str
    kind: str                      # "direct" | "spawn"
    days: str = "*"
    hours: str = "*"
    minutes: str = "*"
    task: str = ""                 # spawn: task text; direct: suite-relative script
    max_steps: int = 8

    def validate(self) -> None:
        if not self.id or not isinstance(self.id, str):
            raise ContractError("JobSpec.id must be a non-empty string")
        if self.kind not in ("direct", "spawn"):
            raise ContractError(f"JobSpec.kind must be 'direct' or 'spawn', got {self.kind!r}")
        if not isinstance(self.max_steps, int) or self.max_steps < 1:
            raise ContractError("JobSpec.max_steps must be a positive int")


@dataclass
class JobResult:
    ok: bool
    summary: str
    artifacts: list = field(default_factory=list)   # suite-relative paths written
    error: str | None = None


@dataclass
class ScriptResult:
    """Outcome of Runtime.run_script().

    returncode mirrors the process exit status (-1 when the adapter killed
    the process on timeout rather than the process exiting itself).
    output is the combined stdout/stderr tail — adapters cap it; the full
    stream belongs to the substrate's own logs, not the contract.
    """
    returncode: int
    output: str
    timed_out: bool = False


# --------------------------------------------------------------------------
# Abstract substrate surface
# --------------------------------------------------------------------------

class MemoryStore(abc.ABC):
    """Namespaced, traversal-safe state. All paths are suite-relative."""

    @abc.abstractmethod
    def read(self, relpath: str) -> str | None:
        """Return file content, or None if missing. Missing is never an error."""

    @abc.abstractmethod
    def write(self, relpath: str, content: str) -> None:
        """Atomic write (tmp+rename where the substrate allows)."""

    @abc.abstractmethod
    def append_text(self, relpath: str, text: str) -> None:
        """Append text; never truncates."""

    def append_jsonl(self, relpath: str, record: dict) -> None:
        self.append_text(relpath, json.dumps(record, ensure_ascii=False) + "\n")

    @abc.abstractmethod
    def exists(self, relpath: str) -> bool:
        """Check existence."""

    @abc.abstractmethod
    def list(self, prefix: str) -> list[str]:
        """List stored paths under a suite-relative prefix."""


class Scheduler(abc.ABC):
    """Cron-shaped job registration. The adapter decides the mechanism."""

    @abc.abstractmethod
    def schedule(self, spec: JobSpec) -> None:
        """Register a job durably (or document non-durability)."""

    @abc.abstractmethod
    def unschedule(self, job_id: str) -> None:
        """Remove a job. Unknown ids are a no-op, not an error."""

    @abc.abstractmethod
    def list_jobs(self) -> list[JobSpec]:
        """List registered jobs."""


class Mind(abc.ABC):
    """Invoke the substrate's mind. Any failure raises MindUnavailable."""

    @abc.abstractmethod
    def invoke(self, prompt: str, *, system: str = "",
               max_steps: int = 8, timeout_s: float = 900) -> str:
        """Return the mind's text. Raises MindUnavailable on any failure —
        never returns an empty/silent success."""


# --------------------------------------------------------------------------
# Safety kernel carried as contract requirements (S1, S2)
# --------------------------------------------------------------------------

# S1: immutable core — never self-mod targets, at every autonomy tier.
# Mirrors core/self-mod/immutable-paths.list (which also lists these).
# Narrowed deliberately (see immutable-paths.list): adapters, jobs, demos
# and tests stay mutable under verification — the contract interface, its
# spec, the dispatch semantics, and the self-mod pipeline itself do not.
IMMUTABLE_CORE_PATTERNS = (
    "skills/prefrontal-cortex-memory/scripts/decide.sh",
    "core/locks/rwlock.sh",
    "core/locks/pid-lock.sh",
    "core/concurrency/semaphore.sh",
    "core/sandbox/sandbox-run.sh",
    "core/executive-load/calc-executive-load.sh",
    "core/self-mod/*",
    "core/runtime/contract.py",
    "core/runtime/RUNTIME_CONTRACT.md",
    "core/runtime/schedule.py",
    "core/runtime/self_mod/*",  # the heart cannot rewrite its own valves
)

# S2: autonomy evidence thresholds (mirror deep-brain-kernel.compute_autonomy_mode).
AUTONOMY_CLEAN_STREAK_TARGET = 20
AUTONOMY_MAX_AUTO_ROLLBACKS = 3
AUTONOMY_WINDOW_DAYS = 30


class Runtime(abc.ABC):
    """One substrate's implementation of the contract."""

    name: str
    memory: MemoryStore
    scheduler: Scheduler
    mind: Mind | None  # None => embedded-mind pattern (job runs in-agent)

    @abc.abstractmethod
    def asset(self, relpath: str) -> str | None:
        """Read-only suite-bundled asset (prompts, manifests), resolved
        against the suite root — never the workspace. None if missing."""

    @abc.abstractmethod
    def log(self, level: str, message: str, **fields) -> None:
        """Structured log to the substrate's normal channel."""

    @abc.abstractmethod
    def provenance(self, event: str, detail: dict) -> None:
        """Append-only audit event {ts, event, actor, detail}. Best-effort:
        must never raise, must never break the caller (S7)."""

    def run_script(self, relpath: str, args: list[str] | None = None,
                   timeout_s: float = 300) -> ScriptResult:
        """Execute a suite-bundled script (direct-kind job). Default:
        unsupported — adapters opt in by overriding. relpath is resolved
        against the suite root, never the workspace (S1). A missing script
        raises ContractError (loud, not silent)."""
        raise ContractError(f"run_script not supported by runtime '{self.name}'")

    # -- S1 -----------------------------------------------------------------
    def check_immutable(self, relpath: str) -> bool:
        """True if relpath matches an immutable-core pattern. Pure helper so
        every adapter enforces the same list the same way."""
        norm = relpath.replace(os.sep, "/").lstrip("/")
        return any(fnmatch.fnmatch(norm, pat) for pat in IMMUTABLE_CORE_PATTERNS)

    # -- S2 -----------------------------------------------------------------
    def autonomy_mode(self, evidence: dict) -> str:
        """Compute steward_mode|auto_mode from persisted evidence. Fail-safe:
        missing, unreadable, or invalid evidence => steward_mode. Autonomy is
        never over-granted on absent evidence."""
        try:
            graduated = bool(evidence.get("graduated"))
            streak_target = int(evidence.get("clean_streak_target")
                                or AUTONOMY_CLEAN_STREAK_TARGET)
            streak = int(evidence.get("clean_streak") or 0)
            unhealthy = int(evidence.get("unhealthy_jobs", 0) or 0)
            rollbacks = int(evidence.get("auto_rollbacks_in_window", 0) or 0)
            cap = int(evidence.get("max_auto_rollbacks")
                      or AUTONOMY_MAX_AUTO_ROLLBACKS)
        except (TypeError, ValueError):
            return "steward_mode"
        if streak < streak_target:
            graduated = False
        if graduated and unhealthy == 0 and rollbacks <= cap:
            return "auto_mode"
        return "steward_mode"


# --------------------------------------------------------------------------
# Portable job logic
# --------------------------------------------------------------------------

class ContractJob(abc.ABC):
    """Job logic written once, against the contract."""

    @abc.abstractmethod
    def spec(self) -> JobSpec:
        """Job descriptor."""

    @abc.abstractmethod
    def build_prompt(self, runtime: Runtime) -> str:
        """Gather context from runtime.memory / runtime.asset and render the
        task text. Pure: no side effects."""

    @abc.abstractmethod
    def complete(self, runtime: Runtime, result_text: str, **kwargs) -> JobResult:
        """Persist results via runtime.memory, emit provenance, return the
        JobResult. Persistence is the runtime's job — never left to the
        mind's tool-use."""

    def run(self, runtime: Runtime) -> JobResult:
        """Full flow for separate-mind runtimes. S3: the dispatch is
        provenance-audited with the exact task text before invocation."""
        if runtime.mind is None:
            raise ContractError(
                "embedded-mind runtime: no separate mind to invoke — run "
                "build_prompt() via the agent's scheduled-task dispatch, "
                "then complete() with the reflection text")
        spec = self.spec()
        spec.validate()
        prompt = self.build_prompt(runtime)
        runtime.provenance("job.spawn", {
            "job": spec.id,
            "provider": runtime.name,
            "task": prompt,
        })
        try:
            text = runtime.mind.invoke(prompt, max_steps=spec.max_steps)
        except MindUnavailable as e:
            runtime.log("error", f"{spec.id}: mind invocation failed", error=str(e))
            return JobResult(ok=False, summary="mind invocation failed",
                             error=str(e))
        return self.complete(runtime, text)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def today_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")
