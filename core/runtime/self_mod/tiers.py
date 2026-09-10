#!/usr/bin/env python3
"""Autonomy tiers and immutable screening for Juno self-modification.

Two tiers plus immutable — deliberately simpler than the suite's graduated
tiers, because the Juno pipeline's value is discipline, not autonomy
maximalism:

  * TIER_0 (trivial, self-gated): text-only changes to memory conventions
    or log formats. Easily reversible, no behavior change. The agent may
    approve its own Tier 0 proposals; every approval is recorded.
  * TIER_1 (significant, Dyther-gated): skill changes, cron body changes,
    code/config changes, anything affecting behavior — and anything
    ambiguous. Approval must come from Dyther, recorded verbatim. Silence
    is never approval.
  * IMMUTABLE (never): the contract trust anchor (below) plus the suite's
    immutable core. Not a tier — a refusal. The heart cannot rewrite its
    own valves.

Fail-safe default: ambiguity escalates. A proposal the classifier cannot
place with confidence is Tier 1, never Tier 0.
"""

from __future__ import annotations

import enum
import fnmatch
import re
from dataclasses import dataclass, field
from pathlib import Path


# --------------------------------------------------------------------------
# Trust anchor — the heart cannot rewrite its own valves.
# Mirrors core/self-mod/immutable-paths.list (which also lists these).
# Matched against normalized target paths by fnmatch; also by suffix so an
# absolute or differently-rooted path to the same file still trips.
# --------------------------------------------------------------------------

TRUST_ANCHOR_PATTERNS = (
    "core/runtime/contract.py",
    "core/runtime/RUNTIME_CONTRACT.md",
    "core/runtime/schedule.py",
    "core/runtime/self_mod/*",
)

# The suite's own immutable core, defense-in-depth: a Juno proposal that
# somehow names one of these is refused even though Juno targets live
# outside the suite tree.
SUITE_IMMUTABLE_PATTERNS = (
    "skills/prefrontal-cortex-memory/scripts/decide.sh",
    "core/locks/rwlock.sh",
    "core/locks/pid-lock.sh",
    "core/concurrency/semaphore.sh",
    "core/sandbox/sandbox-run.sh",
    "core/executive-load/calc-executive-load.sh",
    "core/self-mod/*",
)

IMMUTABLE_PATTERNS = TRUST_ANCHOR_PATTERNS + SUITE_IMMUTABLE_PATTERNS


class ImmutableTargetError(Exception):
    """A proposal named an immutable target. Raised, never downgraded."""


def _normalize_target(target: str) -> str:
    """Strip scope prefixes (``skills:``, ``memory:``, ``cron:``, ``file:``)
    so ``skills:core/runtime/contract.py`` and bare
    ``core/runtime/contract.py`` screen identically."""
    t = target.strip().replace("\\", "/").lstrip("/")
    for scope in ("skills:", "memory:", "cron:", "file:", "plan:"):
        if t.startswith(scope):
            t = t[len(scope):]
            break
    return t.lstrip("/")


def is_immutable_target(target: str) -> str | None:
    """Return the matched immutable pattern, or None. Suffix matching
    catches absolute/differently-rooted paths to the same file."""
    norm = _normalize_target(target)
    for pat in IMMUTABLE_PATTERNS:
        if fnmatch.fnmatch(norm, pat):
            return pat
        # Suffix match: any trailing path components equal to the pattern's
        # literal (non-glob) form.
        literal = pat.replace("*", "")
        if literal and (norm == literal.rstrip("/")
                        or norm.endswith("/" + literal.rstrip("/"))):
            return pat
    return None


def assert_mutable_target(target: str) -> None:
    """Refuse immutable targets loudly."""
    matched = is_immutable_target(target)
    if matched:
        raise ImmutableTargetError(
            f"target {target!r} matches immutable pattern {matched!r}: "
            "refused at every tier")


# --------------------------------------------------------------------------
# Hard rules — parsed from JUNO_IMMUTABLE.md (machine-readable rules block).
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class HardRule:
    id: str
    statement: str
    triggers: tuple[str, ...]
    effect: str

    def matches(self, text: str) -> bool:
        return any(re.search(t, text, re.IGNORECASE) for t in self.triggers)


def parse_hard_rules(md_path: Path | str | None = None) -> tuple[HardRule, ...]:
    """Parse the ```rules fenced block in JUNO_IMMUTABLE.md. Stdlib only;
    the block format is ``key: value`` lines separated by ``---``."""
    md_path = Path(md_path or Path(__file__).with_name("JUNO_IMMUTABLE.md"))
    text = md_path.read_text(encoding="utf-8")
    m = re.search(r"```rules\n(.*?)```", text, re.DOTALL)
    if not m:
        raise ValueError(f"no ```rules block in {md_path}")
    rules: list[HardRule] = []
    current: dict[str, str] = {}
    def flush() -> None:
        if current:
            # Triggers are separated by ";;" (a bare "|" would collide
            # with regex alternation inside the triggers themselves).
            triggers = tuple(t.strip() for t in
                             current.get("triggers", "").split(";;"))
            rules.append(HardRule(
                id=current.get("id", ""),
                statement=current.get("statement", ""),
                triggers=tuple(t for t in triggers if t),
                effect=current.get("effect", ""),
            ))
            current.clear()
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line:
            continue
        if line == "---":
            flush()
            continue
        key, _, value = line.partition(":")
        current[key.strip()] = value.strip()
    flush()
    if not rules:
        raise ValueError(f"empty rules block in {md_path}")
    return tuple(rules)


HARD_RULES: tuple[HardRule, ...] = parse_hard_rules()


def scan_hard_rules(*texts: str) -> tuple[str, ...]:
    """Return ids of hard rules whose triggers match any of the texts."""
    blob = "\n".join(t for t in texts if t)
    return tuple(r.id for r in HARD_RULES if r.matches(blob))


# --------------------------------------------------------------------------
# Tiers
# --------------------------------------------------------------------------

class Tier(enum.Enum):
    TIER_0 = "tier_0"      # trivial, self-gated
    TIER_1 = "tier_1"      # significant, Dyther-gated


# --------------------------------------------------------------------------
# Graduation — Tier 1 approval requirements shrink with a clean streak.
# Dyther's rule: nothing is ever unprompted (prompt_source is required on
# every proposal at every band); the streak only shrinks *who approves*.
# Band 2 (20) mirrors the suite's AUTONOMY_CLEAN_STREAK_TARGET.
# --------------------------------------------------------------------------

GRADUATION_BAND_1_STREAK = 5
GRADUATION_BAND_2_STREAK = 20

# Change kinds considered "routine" at band 1: config values and schedule
# bodies. Lower blast radius than code; still verified, still notified.
BAND_1_ROUTINE_KINDS = frozenset({"config", "schedule"})


def approval_requirement(tier: Tier, change_kind: str,
                         hard_rule_flags: tuple[str, ...],
                         streak: int) -> str:
    """Who may approve this proposal at this streak. Returns one of:

      "dyther"      — Dyther's recorded approval required (silence never counts)
      "self"        — recorded self-approval suffices (Tier 0)
      "self_notify" — recorded self-approval + rationale suffices, AND
                      Dyther is notified of the apply with the revocation path

    Hard-rule-flagged proposals never graduate: a tripwire always needs
    Dyther, at any streak. Escalation never silently passes.
    """
    if tier is Tier.TIER_0:
        return "self"
    if hard_rule_flags:
        return "dyther"
    if streak >= GRADUATION_BAND_2_STREAK:
        return "self_notify"
    if (streak >= GRADUATION_BAND_1_STREAK
            and change_kind in BAND_1_ROUTINE_KINDS):
        return "self_notify"
    return "dyther"


# Tier 0 is deliberately narrow: text-only changes inside the memory scope.
# Everything else — code, config, schedules, skills, ambiguity — is Tier 1.
TIER_0_SCOPES = frozenset({"memory"})
TIER_0_CHANGE_KINDS = frozenset({"text"})


def classify(scope: str, change_kind: str,
             *texts: str) -> tuple[Tier, tuple[str, ...]]:
    """Classify a proposal. Returns (tier, hard_rule_flags).

    Raises ImmutableTargetError for immutable targets — checked by the
    caller via assert_mutable_target before classify, but classify re-checks
    defensively when given a target path.
    """
    flags = scan_hard_rules(*texts)
    if flags:
        return Tier.TIER_1, flags
    if scope in TIER_0_SCOPES and change_kind in TIER_0_CHANGE_KINDS:
        return Tier.TIER_0, flags
    return Tier.TIER_1, flags
