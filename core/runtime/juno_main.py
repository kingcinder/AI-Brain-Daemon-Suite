#!/usr/bin/env python3
"""Production wiring for the Juno runtime — the sewn-up incision.

Constructs the substrate-independent runtime against the agent's REAL
directories (not test sandboxes):

  * memory store  -> the agent's live memory tree (~/memory)
  * self-mod      -> ~/workspace/skills (skills scope),
                     ~/memory (memory scope)

This module constructs only. It submits no proposals, approves nothing,
and starts no autonomous loop. The heart beats when a prompt source
(the weekly reflection, the agent, or Dyther directly) submits the first
proposal — every one of which still passes through verify -> gate ->
apply -> monitor, with Tier 1 gated per the graduation bands.

Usage (from the repo root):
    python3 -c "
    from core.runtime.juno_main import get_pipeline
    pipe = get_pipeline()  # constructed; nothing submitted, nothing applied
    "
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from .adapters.juno import JunoRuntime
from .journal import Journal
from .self_mod import GateRefused, approval_requirement
from .self_mod.pipeline import Pipeline
from .self_mod.proposal import Proposal
from .self_mod.store import ProposalStore


def get_runtime() -> JunoRuntime:
    """The live Juno runtime. Defaults already target the real trees;
    spelled out here so production wiring is explicit, not accidental."""
    home = Path.home()
    return JunoRuntime(
        root=home / ".juno-brain",
        # suite_root defaults to the repo containing this file
        skills_root=home / "workspace" / "skills",
        memory_root=home / "memory",
    )


def get_pipeline(runtime: JunoRuntime | None = None) -> Pipeline:
    """The beating heart, constructed against the live runtime.
    Construction only — no proposals, no approvals, no loop."""
    rt = get_runtime() if runtime is None else runtime
    return Pipeline(rt, rt.self_mod)


def get_store(runtime: JunoRuntime | None = None) -> ProposalStore:
    """Proposal persistence — the heart's memory between beats."""
    rt = get_runtime() if runtime is None else runtime
    return ProposalStore(rt.memory.root)


# Stages the beat may advance on its own. Everything else needs the
# agent (approvals, attestations, cron reads) or Dyther (Tier 1).
_BEAT_ADVANCE = ("draft", "proposed", "verified", "approved", "applied")


def _advance(pipe: Pipeline, store: ProposalStore,
             proposal: Proposal) -> list[dict]:
    """Push one proposal through every automatable stage it can take
    this beat. Returns the list of transitions made.

    The gate is assessed but never auto-passed: a GateRefused for lack
    of approval (or pending agent checks) is the normal awaiting-hands
    state, reported by the heartbeat — not an error."""
    made: list[dict] = []
    while proposal.status in _BEAT_ADVANCE:
        before = proposal.status
        halt = False
        try:
            if before == "draft":
                pipe.submit(proposal)
            elif before == "proposed":
                pipe.verify(proposal)
            elif before == "verified":
                try:
                    pipe.gate(proposal)
                except GateRefused:
                    # Awaiting approval/agent checks: no progress is
                    # possible this beat. Reported below, not an error.
                    halt = True
                # gate() never approves; it only verifies a recorded
                # approval exists. If it passed, apply/monitor may follow
                # in this same beat.
            elif before == "approved":
                pipe.apply(proposal)
                halt = proposal.status == "plan_issued"
            elif before == "applied":
                pipe.monitor(proposal)
        except Exception as exc:  # one proposal never stops the beat
            return made + [{"id": proposal.id, "error": str(exc)[:200]}]
        if proposal.status != before:
            made.append({"id": proposal.id, "from": before,
                         "to": proposal.status})
            store.save(proposal)
        if halt or proposal.status in ("rejected", "rolled_back"):
            break
    return made


def heartbeat(runtime: JunoRuntime | None = None) -> dict:
    """One beat of the heart.

    1. Loads every proposal from the store and advances each through its
       automatable stages (submit -> verify -> gate-assess -> apply ->
       monitor). Approvals, attestations, and cron reads are the agent's;
       Tier 1 approvals are Dyther's — the beat reports them, never acts.
    2. Reconciles each target against its LATEST journaled state (quiet on
       match). Divergence opens a repair draft in the store.
    3. Runs the journal's health check against its own recorded history.
    4. Journals the beat itself as a health signal.

    Returns a report dict for the cron worker: what advanced, what needs
    the agent, what needs Dyther. Idempotent and exception-safe per
    proposal — a beat never loses its rhythm to one bad proposal.
    """
    rt = get_runtime() if runtime is None else runtime
    pipe = Pipeline(rt, rt.self_mod)
    store = ProposalStore(rt.memory.root)
    journal = Journal(rt.memory)

    report: dict = {
        "beat_at": datetime.now(timezone.utc).isoformat(),
        "advanced": [], "errors": [],
        "needs_agent": [], "needs_dyther": [],
        "reconciled": [], "repair_drafts": [],
        "health_anomalies": [],
        "streak": pipe.graduation.streak,
    }

    proposals = {p.id: p for p in store.all()}

    # -- 1. advance -------------------------------------------------------
    for pid, p in sorted(proposals.items()):
        for step in _advance(pipe, store, p):
            if "error" in step:
                report["errors"].append(step)
            else:
                report["advanced"].append(step)
        # -- what still needs hands ------------------------------------
        if p.status == "verified":
            req = (p.gate_requirement
                   or approval_requirement(p.tier, p.change_kind,
                                           p.hard_rule_flags,
                                           pipe.graduation.streak))
            if p.agent_checks_clear():
                need = {"id": pid, "kind": "approval",
                        "gate_requirement": req,
                        "tier": p.tier.value if p.tier else None,
                        "detail": "gate assessed; needs a recorded approval "
                                  "(self per graduation band, else Dyther)"}
            else:
                pending = [c.get("description", "?") for c in p.agent_checks
                           if c.get("passed") is not True]
                need = {"id": pid, "kind": "agent_checks",
                        "gate_requirement": req,
                        "detail": f"resolve agent checks: {pending}"}
            if req == "dyther":
                report["needs_dyther"].append(need)
            else:
                report["needs_agent"].append(need)
        elif p.status == "plan_issued":
            report["needs_agent"].append({
                "id": pid, "kind": "attestation",
                "detail": "execute the plan, then attest with the "
                          "read-back as observed_state"})
        elif p.status == "done" and p.scope == "cron":
            report["needs_agent"].append({
                "id": pid, "kind": "cron_reconcile",
                "detail": "fresh-read the cron body and reconcile it "
                          "against the journaled state"})

    # -- 2. reconcile file targets against their latest journaled state --
    seen_targets: dict[str, str] = {}  # target -> owning proposal id
    for pid, p in sorted(proposals.items()):
        if p.status != "done" or p.scope == "cron":
            continue
        target = f"{p.scope}:{p.target}"
        latest = journal.latest_state_for_target(target)
        if latest and latest.get("proposal") == pid:
            seen_targets[target] = pid
    for target, pid in sorted(seen_targets.items()):
        p = proposals[pid]
        try:
            res = pipe.reconcile(p, quiet=True)
        except Exception as exc:
            report["errors"].append({"id": pid, "error": str(exc)[:200]})
            continue
        report["reconciled"].append({"id": pid, "target": target,
                                     "match": res["match"]})
        if not res["match"] and res["repair_proposal"] is not None:
            store.save(res["repair_proposal"])
            report["repair_drafts"].append(res["repair_proposal"].id)

    # -- 3. health check ---------------------------------------------------
    try:
        report["health_anomalies"] = journal.daily_health_check()
    except Exception as exc:
        report["errors"].append({"id": "health_check",
                                 "error": str(exc)[:200]})

    # -- 4. journal the beat -----------------------------------------------
    try:
        journal.record_signal(
            "self_mod.heartbeat", 1, unit="beat",
            note=(f"advanced={len(report['advanced'])} "
                  f"needs_agent={len(report['needs_agent'])} "
                  f"needs_dyther={len(report['needs_dyther'])} "
                  f"reconciled={len(report['reconciled'])} "
                  f"divergences={len(report['repair_drafts'])} "
                  f"anomalies={len(report['health_anomalies'])}"))
    except Exception:
        pass  # journaling never breaks the beat

    return report
