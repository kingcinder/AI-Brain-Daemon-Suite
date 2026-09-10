#!/usr/bin/env python3
"""Clean-streak graduation: Tier 1 approval requirements shrink as the
pipeline proves itself. Mirrors the suite's 20-clean graduation semantics
(contract AUTONOMY_CLEAN_STREAK_TARGET).

Dyther's rules, encoded:
  * Nothing is ever unprompted — every proposal carries a prompt_source
    (dyther_direct | weekly_review | scheduled), required at construction,
    at every band. The streak only shrinks *who approves*, never *whether
    a prompt exists*.
  * Approvals never expire unless revoked — there is no TTL anywhere in
    this module; only explicit revocation ends an approval.
  * A rollback (or any post-apply failure) resets the streak to zero.
    Trust is re-earned, not resumed.

Bands (see tiers.approval_requirement for the enforcement):
  * streak < 5:   Tier 1 always needs Dyther's recorded approval.
  * 5 <= streak < 20: routine Tier 1 (config/schedule change kinds) may
    self-approve with a recorded rationale AND a notification to Dyther.
    Code/behavioral changes stay Dyther-gated.
  * streak >= 20 (graduated): all Tier 1 may self-approve with rationale
    + notification. Hard-rule-flagged proposals NEVER graduate — tripwires
    always need Dyther, at any streak.

The streak counts clean applies: proposed -> verified -> approved ->
applied -> done with the monitor green and no rollback. A proposal
rejected at verification never touched anything, so it neither increments
nor resets — the pipeline working as designed is not a failure.
"""

from __future__ import annotations

import json


STATE_PATH = "self_mod/graduation.json"


class GraduationTracker:
    """Persisted clean-streak counter backed by the runtime memory store."""

    def __init__(self, memory):
        self.memory = memory

    def _load(self) -> dict:
        raw = self.memory.read(STATE_PATH)
        if not raw:
            return {"clean_streak": 0, "total_applies": 0, "rollbacks": 0}
        try:
            state = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            # Corrupt state fails safe: streak restarts, history preserved
            # by the per-proposal audit logs, not by this counter.
            return {"clean_streak": 0, "total_applies": 0, "rollbacks": 0,
                    "state_corrupt": True}
        return {
            "clean_streak": int(state.get("clean_streak", 0)),
            "total_applies": int(state.get("total_applies", 0)),
            "rollbacks": int(state.get("rollbacks", 0)),
        }

    def _save(self, state: dict) -> None:
        self.memory.write(STATE_PATH, json.dumps(state, indent=2) + "\n")

    @property
    def streak(self) -> int:
        return self._load()["clean_streak"]

    def record_clean(self) -> int:
        """A full propose->done cycle with no rollback. Returns new streak."""
        state = self._load()
        state["clean_streak"] += 1
        state["total_applies"] += 1
        self._save(state)
        return state["clean_streak"]

    def record_failure(self) -> None:
        """Post-apply failure or rollback: streak resets to zero."""
        state = self._load()
        state["clean_streak"] = 0
        state["total_applies"] += 1
        state["rollbacks"] += 1
        self._save(state)
