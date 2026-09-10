#!/usr/bin/env python3
"""Self-modification pipeline: propose -> verify -> gate -> apply -> monitor.

The proposal generator is the embedded mind (the agent) — this module
provides structure and enforcement, not judgment. Every transition is
recorded to the runtime's memory store (``self_mod/proposals/<id>.jsonl``)
and to provenance.

Enforcement invariants (no exceptions, no overrides):
  * submit() refuses proposals without a valid prompt_source — nothing is
    ever unprompted, at any graduation band.
  * apply() refuses any proposal whose status is not "verified".
  * gate() refuses any tier with unresolved agent checks, and enforces the
    graduation-band requirement: streak 0 => every Tier 1 needs Dyther;
    clean streak shrinks the requirement for routine Tier 1, never for
    hard-rule-flagged proposals (tripwires always need Dyther).
  * Approvals never expire — only explicit revocation ends them. A revoked
    approval counts as absent; revocation never auto-rolls-back.
  * monitor() re-runs the automated verification steps post-apply; on
    success the clean streak increments, on failure it resets to zero and
    rolls back automatically.
  * The pipeline never approves, never resolves agent checks, never
    infers — those are the agent's (and Dyther's) alone.
"""

from __future__ import annotations

from dataclasses import asdict
from pathlib import Path

from .apply import Applier, ApplyResult, BackupRecord, RollbackResult
from .graduation import GraduationTracker
from .proposal import PROMPT_SOURCES, Proposal, StatusTransitionError, utc_now_iso
from .tiers import Tier, approval_requirement, classify, is_immutable_target
from .verify import VerificationResult, Verifier


class GateRefused(Exception):
    """The tier gate refused — apply is blocked."""


class Pipeline:
    def __init__(self, runtime, capability):
        """
        runtime: a Runtime (memory + provenance for the audit trail).
        capability: JunoSelfMod — target resolution, plan emission, backups.
        """
        self.runtime = runtime
        self.capability = capability
        self.verifier = Verifier(capability.resolve_target)
        self.applier = Applier(capability.resolve_target,
                               emit_plan=capability.issue_cron_plan,
                               backup_root=capability.backup_root)
        self.graduation = GraduationTracker(runtime.memory)

    # -- audit ----------------------------------------------------------------
    def _record(self, proposal: Proposal, event: str, **detail) -> None:
        entry = {"ts": utc_now_iso(), "event": event,
                 "proposal": proposal.id, "status": proposal.status,
                 "tier": proposal.tier.value if proposal.tier else None,
                 "detail": detail}
        try:
            self.runtime.memory.append_jsonl(
                f"self_mod/proposals/{proposal.id}.jsonl", entry)
        except Exception:
            pass  # audit is best-effort; enforcement never depends on it
        try:
            self.runtime.provenance(f"self_mod.{event}",
                                    {"proposal": proposal.id, **detail})
        except Exception:
            pass

    # -- stages -----------------------------------------------------------------
    def submit(self, proposal: Proposal) -> Proposal:
        """Classify the tier and screen immutable targets."""
        # Defense in depth: the constructor already requires prompt_source,
        # but submit re-asserts — a proposal object built by other means
        # must not slip through.
        assert proposal.prompt_source in PROMPT_SOURCES, (
            f"proposal {proposal.id} has no valid prompt_source — "
            "nothing is ever unprompted")
        matched = is_immutable_target(f"{proposal.scope}:{proposal.target}")
        if matched is None:
            matched = is_immutable_target(proposal.target)
        if matched:
            proposal.transition("rejected",
                                f"immutable target ({matched})")
            self._record(proposal, "rejected", reason="immutable_target",
                         pattern=matched)
            return proposal
        tier, flags = classify(proposal.scope, proposal.change_kind,
                               proposal.target, proposal.change,
                               proposal.rationale,
                               proposal.new_content or "")
        proposal.tier = tier
        proposal.hard_rule_flags = flags
        proposal.transition("proposed",
                            f"tier={tier.value} flags={list(flags)}")
        self._record(proposal, "proposed", tier=tier.value,
                     hard_rule_flags=list(flags))
        return proposal

    def verify(self, proposal: Proposal) -> VerificationResult:
        if proposal.status != "proposed":
            raise StatusTransitionError(
                f"verify requires status 'proposed', got {proposal.status!r}")
        result = self.verifier.verify(proposal)
        if result.ok:
            proposal.transition("verified",
                                f"{len(result.stages)} stages passed; "
                                f"agent checks pending: "
                                f"{result.agent_checks_pending}")
        else:
            failed = [s.name for s in result.stages if not s.ok]
            proposal.transition("rejected",
                                f"verification failed: {failed}")
        self._record(proposal, "verified" if result.ok else "rejected",
                     stages=[{"name": s.name, "ok": s.ok, "detail": s.detail}
                             for s in result.stages])
        return result

    def gate(self, proposal: Proposal) -> None:
        """Tier gate. Raises GateRefused on any failure — apply stays blocked.

        The requirement comes from the graduation band: at streak 0 every
        Tier 1 needs Dyther; as the clean streak grows, routine Tier 1 may
        self-approve with rationale + notification. Hard-rule-flagged
        proposals never graduate — tripwires always need Dyther.
        """
        if proposal.status != "verified":
            raise GateRefused(
                f"gate requires status 'verified', got {proposal.status!r}")
        if not proposal.agent_checks_clear():
            pending = [c["description"] for c in proposal.agent_checks
                       if c["passed"] is not True]
            raise GateRefused(
                f"{len(pending)} agent check(s) unresolved: {pending}")
        req = approval_requirement(
            proposal.tier, proposal.change_kind,
            proposal.hard_rule_flags, self.graduation.streak)
        if req == "dyther":
            if not proposal.dyther_approved():
                raise GateRefused(
                    "Tier 1 requires Dyther's recorded approval — "
                    "silence is never approval")
        else:  # "self" or "self_notify"
            if not proposal.self_approved():
                raise GateRefused(
                    f"gate requires a recorded self-approval "
                    f"(requirement={req}) — silence is never approval")
        proposal.gate_requirement = req
        proposal.transition("approved", f"gate passed (requirement={req})")
        self._record(proposal, "approved", requirement=req)

    def apply(self, proposal: Proposal) -> ApplyResult:
        if proposal.status != "approved":
            raise GateRefused(
                f"apply requires status 'approved' (verified + gated), "
                f"got {proposal.status!r}")
        try:
            result = self.applier.apply(proposal)
        except Exception:
            # The change never landed cleanly — the streak resets.
            self.graduation.record_failure()
            self._record(proposal, "apply_failed")
            raise
        if result.plan_path:
            proposal.transition("plan_issued",
                                f"plan at {result.plan_path}")
        else:
            proposal.transition("applied", result.detail)
        self._record(proposal, proposal.status,
                     backup=(result.backup.backup_dir if result.backup else None),
                     plan=result.plan_path)
        if proposal.gate_requirement == "self_notify":
            self._notify_dyther(proposal)
        return result

    def _notify_dyther(self, proposal: Proposal) -> None:
        """Graduated self-approval is never silent: record a notification
        for Dyther with what changed, why, and the revocation path. The
        pipeline records; the agent surfaces it (weekly review / next
        conversation). Delivery is the agent's job — this file is the proof
        the notification exists."""
        statements = [a.statement for a in proposal.approvals
                      if a.approver == "self" and not a.revoked]
        body = (
            f"# Self-mod notification — proposal {proposal.id}\n\n"
            f"Applied under graduated self-approval "
            f"(gate requirement: self_notify, "
            f"clean streak at gate: {self.graduation.streak}).\n\n"
            f"- scope/target: {proposal.scope}:{proposal.target}\n"
            f"- change: {proposal.change}\n"
            f"- rationale: {proposal.rationale}\n"
            f"- prompt source: {proposal.prompt_source}\n"
            f"- self-approval rationale: "
            f"{statements[-1] if statements else '(none recorded)'}\n\n"
            f"If this change should not stand, revoke the approval: the "
            f"pipeline's revoke() marks it absent and flags the proposal "
            f"for re-review. Rollback is a separate explicit decision.\n"
        )
        try:
            self.runtime.memory.write(
                f"self_mod/notifications/{proposal.id}.md", body)
        except Exception:
            pass
        self._record(proposal, "notified_dyther")

    def revoke(self, proposal: Proposal, approver: str,
               note: str = "") -> None:
        """Revoke an approval on a proposal. Never expires on its own —
        only this ends it. Revocation blocks future applies under that
        approval and flags the proposal for re-review; it does not
        auto-roll-back an already-applied change."""
        proposal.revoke_approval(approver, note)
        self._record(proposal, "approval_revoked", approver=approver,
                     note=note)

    def monitor(self, proposal: Proposal,
                backup: BackupRecord | None = None) -> RollbackResult | None:
        """Post-apply health check for file targets: re-run the automated
        verification steps. On failure, roll back automatically. Returns
        the RollbackResult when a rollback happened, else None."""
        if proposal.status != "applied":
            raise StatusTransitionError(
                f"monitor requires status 'applied', got {proposal.status!r}")
        failures = []
        for i, step in enumerate(proposal.verification_plan or []):
            if step.get("kind") != "command":
                continue  # agent checks were resolved at the gate
            r = self.verifier._run_step(proposal, i, step)
            if not r.ok:
                failures.append(r.name)
        if not failures:
            proposal.transition("done", "monitor: verification still green")
            self._record(proposal, "done")
            self.graduation.record_clean()
            return None
        self._record(proposal, "monitor_failed", failures=failures)
        self.graduation.record_failure()
        if backup is None:
            proposal.transition("rejected",
                                f"monitor failed {failures} and no backup "
                                "exists — manual intervention required")
            self._record(proposal, "rollback_impossible")
            raise RuntimeError(
                f"monitor failed {failures} with no backup to restore")
        rb = self.applier.rollback(backup)
        if rb.ok:
            proposal.transition("rolled_back",
                                f"monitor failed {failures}; {rb.detail}")
        self._record(proposal, "rolled_back" if rb.ok else "rollback_failed",
                     failures=failures, detail=rb.detail)
        return rb

    def attest_plan_executed(self, proposal: Proposal, note: str = "") -> None:
        """For plan_issued (agent-mediated, e.g. cron) targets: the agent
        executed the plan and verified it. The pipeline cannot observe the
        agent's tools, so it records the attestation honestly as an
        attestation — not as a verification it performed."""
        if proposal.status != "plan_issued":
            raise StatusTransitionError(
                f"attest requires status 'plan_issued', got "
                f"{proposal.status!r}")
        if not note or not note.strip():
            raise ValueError("attestation requires a note describing what "
                             "was executed and how it was verified")
        proposal.transition("done", f"agent attests: {note.strip()}")
        self._record(proposal, "done", attestation=note.strip())
