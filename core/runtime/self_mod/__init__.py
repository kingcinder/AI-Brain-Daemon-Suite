"""Juno self-modification pipeline — the heart.

Discipline, not power: proposals are explicit, verified, tier-gated,
logged, and reversible. The embedded mind (the agent) generates proposals;
this package provides structure and enforcement.

Modules:
  proposal  — proposal data model + status machine
  tiers     — Tier 0/1 + immutable screening + hard rules (JUNO_IMMUTABLE.md)
  verify    — verification stages; failed verification blocks apply
  apply     — snapshot/apply/rollback; rollback is hash-proven
  pipeline  — propose -> verify -> gate -> apply -> monitor orchestration
  juno_capability — the pipeline's hands on the agent runtime
"""

from .apply import Applier, ApplyResult, BackupRecord, RollbackResult
from .juno_capability import JunoSelfMod
from .pipeline import GateRefused, Pipeline
from .proposal import (Approval, Proposal, StatusTransitionError,
                       utc_now_iso)
from .tiers import (HARD_RULES, HardRule, ImmutableTargetError, Tier,
                    assert_mutable_target, classify, is_immutable_target,
                    parse_hard_rules, scan_hard_rules)
from .verify import StageResult, VerificationResult, Verifier

__all__ = [
    "Applier", "ApplyResult", "Approval", "BackupRecord", "GateRefused",
    "HARD_RULES", "HardRule", "ImmutableTargetError", "JunoSelfMod",
    "Pipeline", "Proposal", "RollbackResult", "StageResult",
    "StatusTransitionError", "Tier", "VerificationResult", "Verifier",
    "assert_mutable_target", "classify", "is_immutable_target",
    "parse_hard_rules", "scan_hard_rules", "utc_now_iso",
]
