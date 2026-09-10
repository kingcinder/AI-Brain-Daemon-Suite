#!/usr/bin/env python3
"""Verification stage for Juno self-modification proposals.

Stages run in order; any failure short-circuits to REJECTED. A failed
verification BLOCKS apply — no exceptions, no overrides, no "but it's
probably fine". The pipeline's apply() refuses any proposal whose status
is not "verified", and verification is the only path to that status.

Step schema for proposal.verification_plan (list of dicts):
  {"kind": "command", "run": ["python3", "-m", "py_compile", "x.py"],
   "timeout_s": 60}
      — executed here via subprocess. Non-zero exit or timeout => stage fail.
  {"kind": "agent-check", "description": "read the new cron body back via
   cron.view and confirm the schedule survived"}
      — cannot be executed by pipeline code (agent tools are not callable
      here). Recorded as pending on the proposal; the gate refuses to pass
      until the agent resolves each one via record_agent_check(). This is
      the honest seam: the pipeline declares what it cannot check instead
      of pretending.

Stdlib only.
"""

from __future__ import annotations

import hashlib
import py_compile
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .proposal import Proposal, utc_now_iso
from .tiers import assert_mutable_target, scan_hard_rules


@dataclass
class StageResult:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class VerificationResult:
    ok: bool
    stages: list[StageResult] = field(default_factory=list)
    hard_rule_flags: tuple[str, ...] = ()
    agent_checks_pending: list[str] = field(default_factory=list)

    def fail(self, name: str, detail: str = "") -> "VerificationResult":
        self.stages.append(StageResult(name, False, detail))
        self.ok = False
        return self


class Verifier:
    """Runs the verification stages. Needs a target resolver — supplied by
    the capability (JunoSelfMod) so the verifier never invents paths."""

    def __init__(self, resolve_target):
        """
        resolve_target(scope, target) -> pathlib.Path | None.
        Returns the real filesystem path for file scopes, or None for
        virtual (cron) targets.
        """
        self._resolve_target = resolve_target

    # -- public ------------------------------------------------------------
    def verify(self, proposal: Proposal) -> VerificationResult:
        result = VerificationResult(ok=True)

        # Stage 1: immutable screen — hard fail, no exceptions.
        try:
            assert_mutable_target(f"{proposal.scope}:{proposal.target}")
            assert_mutable_target(proposal.target)
        except Exception as e:  # ImmutableTargetError (or ValueError)
            return result.fail("immutable_screen", str(e))

        # Stage 1b: hard-rule tripwires on the proposal text.
        flags = scan_hard_rules(proposal.target, proposal.change,
                                proposal.rationale,
                                proposal.new_content or "")
        result.hard_rule_flags = flags
        proposal.hard_rule_flags = flags
        result.stages.append(StageResult(
            "hard_rule_scan", True,
            f"flags={list(flags)}" if flags else "clean"))

        # Stage 2: target resolution.
        path = self._resolve_target(proposal.scope, proposal.target)
        if proposal.scope == "cron":
            if path is not None:
                return result.fail("target_resolution",
                                   "cron targets must not resolve to files")
            result.stages.append(StageResult("target_resolution", True,
                                             "virtual cron target"))
        else:
            if path is None or not path.exists():
                return result.fail(
                    "target_resolution",
                    f"target does not exist: {proposal.scope}:{proposal.target}")
            if not path.is_file():
                return result.fail("target_resolution",
                                   f"target is not a file: {path}")
            result.stages.append(StageResult("target_resolution", True,
                                             str(path)))

        # Stage 3: change safety.
        if proposal.scope != "cron":
            safety = self._check_change_safety(proposal, path)
            result.stages.append(safety)
            if not safety.ok:
                result.ok = False
                return result
        else:
            if not proposal.new_content or not proposal.new_content.strip():
                return result.fail("change_safety",
                                   "cron proposals require new_content "
                                   "(the new cron body)")
            result.stages.append(StageResult("change_safety", True,
                                             "cron body present"))

        # Stage 4: rollback plan present (the code snapshots regardless;
        # the plan documents intent for the reviewer).
        if not proposal.rollback_plan or not proposal.rollback_plan.strip():
            return result.fail("rollback_plan",
                               "rollback_plan is required, even though the "
                               "pipeline snapshots automatically")
        result.stages.append(StageResult("rollback_plan", True, "present"))

        # Stage 5: execute the verification plan.
        for i, step in enumerate(proposal.verification_plan or []):
            step_result = self._run_step(proposal, i, step)
            result.stages.append(step_result)
            if not step_result.ok:
                result.ok = False
                return result
            if step.get("kind") == "agent-check":
                result.agent_checks_pending.append(
                    step.get("description", f"step {i}"))
                proposal.record_agent_check(
                    step.get("description", f"step {i}"),
                    passed=None, note="pending agent execution")

        return result

    # -- internals ----------------------------------------------------------
    def _check_change_safety(self, proposal: Proposal,
                             path: Path) -> StageResult:
        if proposal.new_content is None:
            return StageResult("change_safety", False,
                               "new_content is required for file targets")
        content = proposal.new_content
        if not content.strip():
            return StageResult("change_safety", False,
                               "new_content is empty")
        if len(content.encode("utf-8")) > 1_000_000:
            return StageResult("change_safety", False,
                               "new_content exceeds 1MB safety bound")
        if "\x00" in content:
            return StageResult("change_safety", False,
                               "new_content contains NUL bytes")
        # Python syntax check for Python files — cheap, loud, no execution.
        # Keyed off the file suffix, not the change-kind label: a .md skill
        # change can be behavior-affecting ("code" kind) without being
        # Python.
        if path.suffix == ".py":
            try:
                compile(content, str(path), "exec")
            except SyntaxError as e:
                return StageResult("change_safety", False,
                                   f"syntax error in new_content: {e}")
        return StageResult("change_safety", True,
                           f"{len(content)} chars, sha256="
                           f"{hashlib.sha256(content.encode()).hexdigest()[:12]}")

    def _run_step(self, proposal: Proposal, i: int,
                  step: dict) -> StageResult:
        kind = step.get("kind")
        if kind == "agent-check":
            return StageResult(f"plan_step_{i}", True,
                               "agent-check recorded as pending; gate "
                               "requires agent resolution")
        if kind == "command":
            run = step.get("run")
            if not run or not isinstance(run, list):
                return StageResult(f"plan_step_{i}", False,
                                   "command step requires a 'run' list")
            timeout = float(step.get("timeout_s", 60))
            try:
                proc = subprocess.run(run, capture_output=True, text=True,
                                      timeout=timeout, cwd=str(Path.home()))
            except subprocess.TimeoutExpired:
                return StageResult(f"plan_step_{i}", False,
                                   f"timed out after {timeout}s: {run}")
            except OSError as e:
                return StageResult(f"plan_step_{i}", False,
                                   f"could not execute: {e}")
            tail = ((proc.stdout or "") + (proc.stderr or ""))[-2000:]
            if proc.returncode != 0:
                return StageResult(
                    f"plan_step_{i}", False,
                    f"exit {proc.returncode}: {run}\n{tail}")
            return StageResult(f"plan_step_{i}", True,
                               f"exit 0: {run}")
        return StageResult(f"plan_step_{i}", False,
                           f"unknown step kind {kind!r}")
