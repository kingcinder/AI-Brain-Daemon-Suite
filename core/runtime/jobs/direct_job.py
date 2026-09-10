#!/usr/bin/env python3
"""Slice 2: direct-kind jobs through the contract.

Where slice 1 (weekly_reflection.py) proved the contract for spawn-kind
jobs (mind invocation), this module proves it for direct-kind jobs — the
majority of the suite's JOBS table. A DirectJob wraps an existing
suite-bundled script and executes it through Runtime.run_script(); the
contract does NOT rewrite the scripts. Script logic stays where it is;
the contract standardizes invocation, timeout, missing-script handling,
provenance, and result reporting across substrates.

Differences from deep-brain-kernel.run_direct (documented, not hidden):
  - Path language: the kernel's direct targets are relative to SKILLS_DIR
    (e.g. "hippocampus-memory/scripts/decay.sh"); the contract's
    run_script() is suite-rooted per S1, so the same job is addressed as
    "skills/hippocampus-memory/scripts/decay.sh". One path language for
    the whole contract, no per-kind exceptions.
  - The kernel retries a non-zero exit once after 5s (transient flakes);
    the contract does not retry — retry policy is kernel-side and would be
    a behavior change on other substrates. A DirectJob failure is final
    and loud; the next scheduled firing retries by schedule.
  - The kernel tracks processes via pidfd for race-free shutdown signaling
    (Pillar 3); the contract's run_script has no pidfd hook — adapters
    document their own shutdown semantics.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from core.runtime.contract import (  # noqa: E402
    ContractError,
    ContractJob,
    JobResult,
    JobSpec,
    Runtime,
    utc_now_iso,
)


class DirectJob(ContractJob):
    """A direct-kind suite job: run script `script` (suite-relative) via
    Runtime.run_script() and report the outcome as a JobResult.

    build_prompt() is informational for direct jobs (no mind is invoked);
    it returns the exact invocation that will run, so provenance still
    records what was executed.
    """

    def __init__(self, job_id: str, script: str, *, days: str = "*",
                 hours: str = "*", minutes: str = "*",
                 args: tuple[str, ...] = (), timeout_s: float = 300):
        self.job_id = job_id
        self.script = script
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.args = args
        self.timeout_s = timeout_s

    def spec(self) -> JobSpec:
        return JobSpec(id=self.job_id, kind="direct", days=self.days,
                       hours=self.hours, minutes=self.minutes,
                       task=self.script)

    def build_prompt(self, runtime: Runtime) -> str:
        arg_str = " ".join(self.args)
        return (f"Direct job '{self.job_id}': execute suite script "
                f"{self.script} {arg_str} (timeout {self.timeout_s:.0f}s). "
                f"No mind invocation; the script runs via "
                f"Runtime.run_script on '{runtime.name}'.")

    def complete(self, runtime: Runtime, result_text: str,
                 **kwargs) -> JobResult:
        script_result = kwargs.get("script_result")
        if script_result is None:
            raise ContractError(f"{self.job_id}: complete() requires "
                                "script_result kwarg for direct jobs")
        ok = (script_result.returncode == 0 and not script_result.timed_out)
        runtime.provenance("job.direct", {
            "job": self.job_id,
            "script": self.script,
            "returncode": script_result.returncode,
            "timed_out": script_result.timed_out,
            "ok": ok,
        })
        summary = (f"script {self.script} exited 0"
                   if ok else
                   f"script {self.script} failed "
                   f"(rc={script_result.returncode}, "
                   f"timed_out={script_result.timed_out})")
        return JobResult(
            ok=ok,
            summary=summary,
            artifacts=[],
            error=None if ok else script_result.output[-500:],
        )

    def run(self, runtime: Runtime) -> JobResult:
        """Direct jobs never touch runtime.mind — they work on every
        adapter, including embedded-mind runtimes."""
        spec = self.spec()
        spec.validate()
        runtime.provenance("job.direct", {
            "job": spec.id,
            "script": self.script,
            "args": list(self.args),
            "provider": runtime.name,
            "task": self.build_prompt(runtime),
        })
        try:
            result = runtime.run_script(self.script, list(self.args),
                                        timeout_s=self.timeout_s)
        except ContractError as e:
            runtime.log("error", f"{spec.id}: script execution failed",
                        error=str(e))
            return JobResult(ok=False,
                             summary="script execution failed",
                             error=str(e))
        return self.complete(runtime, result.output, script_result=result)


def hippocampus_decay_job() -> DirectJob:
    """The suite's hippocampus_decay JOBS entry as a ContractJob.

    Mirrors deep-brain-kernel.JOBS: direct, days "3", hours "2", target
    hippocampus-memory/scripts/decay.sh. (The JOBS entry pins no minute
    value beyond the table's global uniqueness; the slice uses the slot
    the kernel check reports.)
    """
    return DirectJob(
        job_id="hippocampus_decay",
        script="skills/hippocampus-memory/scripts/decay.sh",
        days="3",
        hours="2",
        minutes="*",
        timeout_s=300,
    )
