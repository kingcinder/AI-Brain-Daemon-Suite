#!/usr/bin/env python3
"""Proposal data model for Juno self-modification.

A proposal is an explicit, reviewable unit of intended change. The embedded
mind (the agent) authors proposals; this module provides the structure and
the status machine — never the judgment.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone

from .tiers import Tier


# Legal status transitions. Anything else raises StatusTransitionError —
# the pipeline cannot skip verification or gating by "forgetting" a step.
LEGAL_TRANSITIONS = {
    "draft": ("proposed", "rejected"),
    "proposed": ("verified", "rejected"),
    "verified": ("approved", "rejected"),
    "approved": ("applied", "plan_issued", "rejected"),
    "applied": ("rolled_back", "done"),
    "plan_issued": ("done", "rejected"),
    "rejected": (),
    "rolled_back": (),
    "done": (),
}


class StatusTransitionError(Exception):
    """An illegal status transition was attempted."""


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass
class Approval:
    approver: str            # "self" | "dyther"
    statement: str           # recorded verbatim; never inferred
    at: str = field(default_factory=utc_now_iso)


@dataclass
class Proposal:
    """One intended change.

    scope: "skills" | "memory" | "cron" — where the target lives.
    target: path within the scope (or cron job id for scope "cron").
    change_kind: "text" | "code" | "config" | "schedule".
    change: human description of what will change and why it is safe.
    new_content: full replacement bytes for file targets (None for cron).
    rationale: link to the review finding that motivates this.
    verification_plan: ordered steps; see verify.py for the step schema.
    rollback_plan: human description of how to undo (the code snapshots
        regardless — this documents intent for the reviewer).
    """

    id: str
    scope: str
    target: str
    change_kind: str
    change: str
    rationale: str
    verification_plan: list[dict] = field(default_factory=list)
    rollback_plan: str = ""
    new_content: str | None = None

    # Pipeline-managed:
    tier: Tier | None = None
    hard_rule_flags: tuple[str, ...] = ()
    status: str = "draft"
    approvals: list[Approval] = field(default_factory=list)
    agent_checks: list[dict] = field(default_factory=list)  # pending/resolved
    history: list[dict] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.scope not in ("skills", "memory", "cron"):
            raise ValueError(f"unknown scope {self.scope!r}")
        if self.change_kind not in ("text", "code", "config", "schedule"):
            raise ValueError(f"unknown change_kind {self.change_kind!r}")
        if not self.target or not self.target.strip():
            raise ValueError("target must be non-empty")
        if ".." in self.target.replace("\\", "/").split("/"):
            raise ValueError(f"target escapes scope: {self.target!r}")

    # -- status machine ----------------------------------------------------
    def transition(self, new_status: str, note: str = "") -> None:
        allowed = LEGAL_TRANSITIONS.get(self.status, ())
        if new_status not in allowed:
            raise StatusTransitionError(
                f"illegal transition {self.status!r} -> {new_status!r} "
                f"for proposal {self.id}")
        self.status = new_status
        self.history.append({"at": utc_now_iso(), "to": new_status,
                             "note": note})

    # -- approvals ----------------------------------------------------------
    def approve_self(self, statement: str) -> None:
        if self.tier is not Tier.TIER_0:
            raise ValueError("self-approval is only valid for Tier 0")
        self.approvals.append(Approval(approver="self", statement=statement))

    def approve_dyther(self, statement: str) -> None:
        if not statement or not statement.strip():
            raise ValueError("Dyther's approval must carry a statement — "
                             "silence is never approval")
        self.approvals.append(Approval(approver="dyther",
                                       statement=statement.strip()))

    def dyther_approved(self) -> bool:
        return any(a.approver == "dyther" for a in self.approvals)

    def self_approved(self) -> bool:
        return any(a.approver == "self" for a in self.approvals)

    # -- agent checks --------------------------------------------------------
    def record_agent_check(self, description: str, passed: bool | None,
                           note: str = "") -> None:
        """Record or resolve one agent-executed verification step. Only the
        agent performing the check may call this — the pipeline never marks
        its own homework complete. Re-recording the same description
        replaces the earlier entry (pending -> resolved)."""
        self.agent_checks = [c for c in self.agent_checks
                             if c["description"] != description]
        self.agent_checks.append({"description": description,
                                  "passed": passed, "note": note,
                                  "at": utc_now_iso()})

    def agent_checks_clear(self) -> bool:
        """True when every recorded agent check passed. Vacuously true when
        the verification plan declared no agent checks."""
        return all(c["passed"] is True for c in self.agent_checks)
