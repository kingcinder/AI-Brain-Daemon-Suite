#!/usr/bin/env python3
"""Juno self-mod capability — the pipeline's hands on the agent runtime.

Real targets, honestly scoped:

  * scope "skills"  -> files under the workspace skills dir (real file I/O,
    backup-able, rollback-able).
  * scope "memory"  -> files under the agent's memory dir (convention files
    like memory/conventions.md — NOT the daily logs, which are append-only
    history and never rewrite targets).
  * scope "cron"    -> virtual. The adapter cannot call the agent's cron
    tool, so apply() emits an executable plan document (the same honest
    pattern as JunoScheduler's schedule-request docs). The agent executes
    it, then records completion via pipeline.attest_plan_executed().

Nothing here reaches the agent's tools. Where the adapter cannot act, it
produces a plan instead of pretending.
"""

from __future__ import annotations

import json
from pathlib import Path

from ..contract import ContractError


class JunoSelfMod:
    """Target resolution + plan emission for the Juno runtime."""

    SCOPES = ("skills", "memory", "cron")

    def __init__(self, runtime,
                 skills_root: Path | str | None = None,
                 memory_root: Path | str | None = None,
                 plans_dir: Path | str | None = None,
                 backup_root: Path | str | None = None):
        self.runtime = runtime
        home = Path.home()
        self.skills_root = Path(skills_root or home / "workspace" / "skills"
                               ).resolve()
        self.memory_root = Path(memory_root or home / "memory").resolve()
        self.plans_dir = Path(plans_dir or home / "self_mod_plans").resolve()
        self.backup_root = Path(backup_root or home / "self_mod_backups"
                                ).resolve()

    # -- target resolution ----------------------------------------------------
    def _scoped_root(self, scope: str) -> Path:
        if scope == "skills":
            return self.skills_root
        if scope == "memory":
            return self.memory_root
        raise ContractError(f"scope {scope!r} has no filesystem root")

    def resolve_target(self, scope: str, target: str) -> Path | None:
        """Resolve to a real path, or None for virtual (cron) targets.
        Traversal escapes are rejected, never rewritten."""
        if scope not in self.SCOPES:
            raise ContractError(f"unknown self-mod scope {scope!r}")
        if scope == "cron":
            return None
        norm = target.replace("\\", "/").lstrip("/")
        if not norm or norm.startswith("/") or ".." in norm.split("/"):
            raise ContractError(f"target rejected: {target!r}")
        root = self._scoped_root(scope)
        resolved = (root / norm).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            raise ContractError(f"target escapes scope root: {target!r}")
        return resolved

    # -- plan emission (virtual targets) ---------------------------------------
    def issue_cron_plan(self, proposal, context: dict | None = None) -> str:
        """Write the executable plan for a cron-body change. The agent must:
        1. record the current body (cron.view) so rollback stays possible;
        2. apply the new body (cron.update);
        3. read it back (cron.view) and confirm;
        4. attest via pipeline.attest_plan_executed() with a verification note.
        """
        self.plans_dir.mkdir(parents=True, exist_ok=True)
        plan = {
            "proposal": proposal.id,
            "scope": "cron",
            "job_id": proposal.target,
            "tier": proposal.tier.value if proposal.tier else None,
            "hard_rule_flags": list(proposal.hard_rule_flags),
            "steps": [
                {"n": 1, "action": "cron.view", "id": proposal.target,
                 "purpose": "record the current body BEFORE changing it — "
                            "this is the rollback"},
                {"n": 2, "action": "cron.update", "id": proposal.target,
                 "body": proposal.new_content,
                 "purpose": "install the new body from this proposal"},
                {"n": 3, "action": "cron.view", "id": proposal.target,
                 "purpose": "read the body back; confirm the change landed "
                            "exactly as proposed"},
                {"n": 4, "action": "pipeline.attest_plan_executed",
                 "purpose": "record what was executed and how step 3 "
                            "verified it — a note AND the observed_state "
                            "(the step-3 read-back) are required; the "
                            "read-back is frozen in the Eternal Journal "
                            "for later reconciliation"},
            ],
            "rollback": ("re-issue cron.update with the body recorded in "
                         "step 1"),
            "rollback_plan": proposal.rollback_plan,
        }
        path = self.plans_dir / f"{proposal.id}.cron-plan.json"
        path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
        try:
            self.runtime.provenance("self_mod.plan_issued",
                                    {"proposal": proposal.id,
                                     "plan": str(path)})
        except Exception:
            pass
        return str(path)
