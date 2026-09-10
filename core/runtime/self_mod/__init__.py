"""Juno self-modification pipeline — the heart.

Discipline, not power: proposals are explicit, verified, tier-gated,
logged, and reversible. The embedded mind (the agent) generates proposals;
this package provides structure and enforcement.

Modules:
  proposal  — proposal data model + status machine (prompt_source required,
              approvals never expire, only revocation ends them)
  tiers     — Tier 0/1 + immutable screening + hard rules (JUNO_IMMUTABLE.md)
              + graduation bands (Tier 1 requirements shrink with clean streak)
  verify    — verification stages; failed verification blocks apply
  apply     — snapshot/apply/rollback; rollback is hash-proven
  graduation — clean-streak tracker; rollback resets to zero
  pipeline  — propose -> verify -> gate -> apply -> monitor orchestration,
              journaled; reconcile() closes the loop through the journal
  juno_capability — the pipeline's hands on the agent runtime

The Eternal Journal (core/runtime/journal.py) is the source of truth:
health signals accumulate into the behavioral baseline, and frozen
post-apply states are what reconciliation checks reality against.
"""

from ..journal import Journal
from .apply import Applier, ApplyResult, BackupRecord, RollbackResult
from .graduation import GraduationTracker
from .juno_capability import JunoSelfMod
from .pipeline import GateRefused, Pipeline
from .proposal import (PROMPT_SOURCES, Approval, Proposal,
                       StatusTransitionError, utc_now_iso)
from .tiers import (HARD_RULES, HardRule, ImmutableTargetError, Tier,
                    approval_requirement, assert_mutable_target, classify,
                    is_immutable_target, parse_hard_rules, scan_hard_rules)
from .verify import StageResult, VerificationResult, Verifier

__all__ = [
    "Applier", "ApplyResult", "Approval", "BackupRecord", "GateRefused",
    "GraduationTracker", "HARD_RULES", "HardRule", "ImmutableTargetError",
    "Journal", "JunoSelfMod", "PROMPT_SOURCES", "Pipeline", "Proposal",
    "RollbackResult", "StageResult", "StatusTransitionError", "Tier",
    "VerificationResult", "Verifier", "approval_requirement",
    "assert_mutable_target", "classify", "is_immutable_target",
    "parse_hard_rules", "scan_hard_rules", "utc_now_iso",
]
