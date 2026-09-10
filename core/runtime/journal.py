#!/usr/bin/env python3
"""The Eternal Journal — the agent's source of truth.

One fix for two open problems:

  1. Monitor health signals (Q3): the post-apply monitor re-runs the
     proposal's own checks, but nothing tracked behavior *over time*.
     The journal accumulates health signals daily; ``daily_health_check()``
     compares recent windows against that recorded history. The journal
     IS the baseline — no pre-declared thresholds, deviation measured
     against what actually happened.

  2. Plan reconciliation (Q4): for agent-mediated targets the pipeline
     records attestation but couldn't verify execution. Now every
     attestation journals the *observed resulting state* (the read-back),
     frozen as a ``state`` block. ``reconcile()`` compares fresh
     observation against that frozen claim. The journal is the claim;
     reality is checked against it. Divergence becomes a repair proposal
     (prompt_source="scheduled") — the loop closes through the journal.

Format: ``journal/YYYY-MM-DD.md`` under the memory-store root. Markdown
prose plus fenced JSON blocks (`````signal``, `````state``, `````anomaly``)
so the file stays human-readable AND machine-queryable. Append-only:
``append()`` never rewrites existing lines — history is not editable.

The journal shape (``journal/*``) is immutable to the self-mod pipeline
(see tiers.TRUST_ANCHOR_PATTERNS): the pipeline may append via this
class, but no proposal may target journal files. The agent writes the
journal directly as its practice; the pipeline is not the agent.
"""

from __future__ import annotations

import json
import re
from datetime import datetime


SECTIONS = ("Health signals", "Self-mod", "Decisions", "Anomalies",
            "Reflection")

SIGNAL_FENCE = "signal"
STATE_FENCE = "state"
ANOMALY_FENCE = "anomaly"


def _today() -> str:
    return datetime.now().date().isoformat()


def _utcnow() -> str:
    return datetime.now().isoformat(timespec="seconds")


class Journal:
    """Append-only daily journal backed by a MemoryStore."""

    def __init__(self, memory):
        self.memory = memory

    # -- writing ---------------------------------------------------------
    def _path(self, day: str) -> str:
        return f"journal/{day}.md"

    def _read_day(self, day: str) -> str:
        return self.memory.read(self._path(day)) or ""

    def _ensure_section(self, text: str, section: str) -> str:
        if f"## {section}" not in text:
            if text and not text.endswith("\n"):
                text += "\n"
            text += f"\n## {section}\n"
        return text

    def append(self, section: str, text: str, day: str | None = None) -> str:
        """Append prose under a section. Returns the day path. Never
        rewrites existing content."""
        if section not in SECTIONS:
            raise ValueError(f"unknown journal section {section!r}; "
                             f"choose from {SECTIONS}")
        day = day or _today()
        body = self._read_day(day)
        if not body:
            body = f"# Journal — {day}\n"
        body = self._ensure_section(body, section)
        if not body.endswith("\n"):
            body += "\n"
        body += f"\n{text.rstrip()}\n"
        self.memory.write(self._path(day), body)
        return self._path(day)

    def _append_block(self, section: str, fence: str, record: dict,
                      day: str | None = None) -> str:
        payload = json.dumps(record, indent=2)
        return self.append(section, f"```{fence}\n{payload}\n```", day=day)

    def record_signal(self, name: str, value: float, unit: str = "",
                      note: str = "", day: str | None = None) -> str:
        """Journal one health-signal observation."""
        return self._append_block("Health signals", SIGNAL_FENCE, {
            "name": name, "value": value, "unit": unit,
            "at": _utcnow(), "note": note,
        }, day=day)

    def record_state(self, proposal_id: str, target: str, state: str,
                     note: str = "", day: str | None = None) -> str:
        """Freeze the observed post-apply state of a proposal's target —
        the claim reconciliation checks reality against."""
        return self._append_block("Self-mod", STATE_FENCE, {
            "proposal": proposal_id, "target": target, "state": state,
            "at": _utcnow(), "note": note,
        }, day=day)

    def record_anomaly(self, kind: str, detail: str,
                       day: str | None = None) -> str:
        return self._append_block("Anomalies", ANOMALY_FENCE, {
            "kind": kind, "detail": detail, "at": _utcnow(),
        }, day=day)

    # -- reading ----------------------------------------------------------
    def _iter_blocks(self, fence: str, days: int,
                     day: str | None = None) -> list[tuple[str, dict]]:
        """Yield (day, record) for fenced JSON blocks, newest day last."""
        out: list[tuple[str, dict]] = []
        from datetime import timedelta
        end_dt = datetime.fromisoformat(day) if day else datetime.now()
        for back in range(days):
            # walk back one day at a time
            day_s = (end_dt - timedelta(days=back)).date().isoformat()
            body = self._read_day(day_s)
            for m in re.finditer(rf"```{fence}\n(.*?)```", body, re.DOTALL):
                try:
                    out.append((day_s, json.loads(m.group(1))))
                except (json.JSONDecodeError, ValueError):
                    continue  # a corrupt block never breaks the reader
        out.sort(key=lambda t: (t[0], t[1].get("at", "")))
        return out

    def signal_history(self, name: str, days: int = 30,
                       day: str | None = None) -> list[tuple[str, float]]:
        """[(day, value)] for a named signal, oldest first."""
        return [(d, float(r["value"]))
                for d, r in self._iter_blocks(SIGNAL_FENCE, days, day)
                if r.get("name") == name and r.get("value") is not None]

    def latest_state(self, proposal_id: str,
                     day: str | None = None) -> dict | None:
        """Most recent frozen state for a proposal, or None."""
        matches = [r for _, r in self._iter_blocks(STATE_FENCE, 90, day)
                   if r.get("proposal") == proposal_id]
        return matches[-1] if matches else None

    # -- health baselining --------------------------------------------------
    def daily_health_check(self, recent_days: int = 7,
                           baseline_days: int = 23,
                           min_baseline_points: int = 5,
                           day: str | None = None) -> list[dict]:
        """Compare each signal's recent window against its own recorded
        history. Flags: recent mean beyond 3 sigma of baseline, or any move
        in a previously flat signal. Conservative by design — the journal
        defines normal, and only clear departures count. Anomalies are
        journaled and returned."""
        total = recent_days + baseline_days
        names: set[str] = set()
        for d, r in self._iter_blocks(SIGNAL_FENCE, total, day):
            if r.get("name"):
                names.add(r["name"])
        anomalies: list[dict] = []
        for name in sorted(names):
            hist = self.signal_history(name, total, day)
            if len(hist) < min_baseline_points + 1:
                continue
            baseline = [v for _, v in hist[:-recent_days]]
            recent = [v for _, v in hist[-recent_days:]]
            if len(baseline) < min_baseline_points or not recent:
                continue
            mean = sum(baseline) / len(baseline)
            var = sum((v - mean) ** 2 for v in baseline) / len(baseline)
            std = var ** 0.5
            rmean = sum(recent) / len(recent)
            if std == 0:
                flagged = rmean != mean  # a flat signal moved: notable
            else:
                flagged = abs(rmean - mean) > 3 * std
            if flagged:
                detail = (f"signal {name!r}: baseline mean {mean:.4g} "
                          f"(n={len(baseline)}, std={std:.4g}) vs recent "
                          f"mean {rmean:.4g} (n={len(recent)})")
                self.record_anomaly("health_deviation", detail, day=day)
                anomalies.append({"signal": name, "baseline_mean": mean,
                                  "baseline_std": std, "recent_mean": rmean,
                                  "detail": detail})
        return anomalies
