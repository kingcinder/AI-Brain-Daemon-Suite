#!/usr/bin/env python3
"""Portable schedule-table logic — extracted from deep-brain-kernel.py.

This module owns the suite's dispatch semantics: the cron-spec language,
the date-qualified dedupe key, and the due_now() predicate. It is pure
(stdlib only, no I/O, no substrate) so any runtime — the kernel's asyncio
loop, a future non-Python scheduler, or an agent-runtime adapter — shares
identical scheduling behavior.

deep-brain-kernel.py imports these names from here; the JOBS table and all
dispatch machinery stay in the kernel. Do not fork this logic — import it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class Job:
    name: str
    kind: str  # "direct" or "spawn"
    hours: str  # "*" or comma-separated ints
    minutes: str  # comma-separated ints
    target: str  # direct: path relative to SKILLS_DIR ; spawn: task text
    days: str = "*"  # "*" or comma-separated weekday ints, Python convention:
                      # 0=Monday .. 6=Sunday (datetime.weekday()). "*" = every day.
    spawn_max_steps: int = 8   # per-job override for agent-loop MAX_STEPS
    thinking_model: bool = False  # when True, auto-append a no-reasoning
                                   # prompt suffix so the model skips chain-of-
                                   # thought and produces tool calls directly
    last_fired_key: Optional[str] = field(default=None, repr=False)


def _spec_matches(spec: str, value: int) -> bool:
    if spec == "*":
        return True
    return str(value) in {s.strip() for s in spec.split(",")}


def _job_key(moment: datetime) -> str:
    """Dedupe key for a scheduling moment: date + hour + minute.

    BUG FIX (preserved verbatim from deep-brain-kernel.py): the key previously
    omitted the date ("H:M" only). A job's last_fired_key is stored per-job
    and never reset, so on the day after a job first fired, today's "H:M"
    would be byte-identical to yesterday's — due_now() would return False
    permanently. Every job would fire exactly once, ever. Including the date
    fixes it; it is what makes weekly jobs viable at all.
    """
    return f"{moment.date().isoformat()}:{moment.hour}:{moment.minute}"


def due_now(job: Job, moment: datetime) -> bool:
    key = _job_key(moment)
    if job.last_fired_key == key:
        return False
    return (_spec_matches(job.days, moment.weekday())
            and _spec_matches(job.hours, moment.hour)
            and _spec_matches(job.minutes, moment.minute))


class ScheduleTable:
    """A portable schedule table: a list of Jobs with a due_at() query.

    Adapters use this to share the kernel's dispatch semantics without
    importing the kernel. The table does not fire jobs — it answers
    "what is due at this moment"; firing stays substrate-side.
    """

    def __init__(self, jobs: list[Job] | None = None):
        self.jobs: list[Job] = list(jobs or [])

    def add(self, job: Job) -> None:
        self.jobs.append(job)

    def due_at(self, moment: datetime) -> list[Job]:
        """Jobs due at `moment` that have not already fired for its key."""
        return [j for j in self.jobs if due_now(j, moment)]

    def mark_fired(self, job: Job, moment: datetime) -> None:
        """Record a firing so the date-qualified dedupe key suppresses
        re-fire within the same minute."""
        job.last_fired_key = _job_key(moment)

    def minute_collisions(self) -> dict[str, list[str]]:
        """Map minute-spec -> job names where >1 job shares the spec.

        The suite's convention is globally unique minute values per table
        (see BRAIN_DAEMON_SCHEDULE.md); this reports violations.
        """
        by_minute: dict[str, list[str]] = {}
        for j in self.jobs:
            by_minute.setdefault(j.minutes, []).append(j.name)
        return {m: names for m, names in by_minute.items() if len(names) > 1}
