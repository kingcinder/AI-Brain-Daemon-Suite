#!/usr/bin/env python3
"""Weekly self-reflection job, written against the runtime contract.

Vertical slice: the suite's ``hippocampus_weekly_reflection`` job
(Sundays 02:44 UTC) re-expressed as contract-defined job logic. Runs on any
:class:`Runtime` adapter.

Flow:
  * separate-mind runtimes (codypc): ``run()`` → build_prompt → mind.invoke
    → complete (persistence by the adapter, deterministically).
  * embedded-mind runtimes (juno): the agent's scheduled-task dispatch calls
    ``build_prompt()``, performs the reflection itself, then calls
    ``complete()`` with the text.

This closes the gap found in the end-to-end trace: under the default
agent-loop provider the mind had no file-write tool for ``memory/self/*.md``,
so persistence was unenforceable. Here ``complete()`` owns persistence.
"""

from __future__ import annotations

from ..contract import (
    ContractJob, ContractError, JobResult, JobSpec, Runtime,
    today_utc, utc_now_iso,
)

#: Suite slot preserved bit-for-bit: Sunday 02:44 UTC (days="6" per
#: datetime.weekday(): 0=Monday..6=Sunday).
JOB_ID = "hippocampus_weekly_reflection"

PROMPT_ASSETS = (
    "skills/hippocampus-memory/prompts/self-reflect.md",
    "skills/hippocampus-memory/prompts/weekly-reflection-event.md",
)

SELF_PATHS = (
    "memory/self/growth.md",
    "memory/self/opinions.md",
    "memory/self/identity.md",
)

#: Fallback when the suite prompt assets are unavailable (e.g. adapter
#: pointed at a bare workspace). The canonical text lives in the assets.
FALLBACK_QUESTIONS = (
    "1. How have I changed this week?\n"
    "2. What opinions have shifted or strengthened?\n"
    "3. How has my relationship with the user evolved?\n"
    "4. What patterns do I notice in myself?\n"
    "5. What am I proud of?\n"
    "6. What do I want to work on?\n"
)


class WeeklyReflectionJob(ContractJob):
    def spec(self) -> JobSpec:
        return JobSpec(
            id=JOB_ID,
            kind="spawn",
            days="6",
            hours="2",
            minutes="44",
            task=("Run weekly self-reflection honestly: how have I changed "
                  "this week, what opinions shifted or strengthened, how has "
                  "the relationship with the user evolved, what patterns do I "
                  "notice in myself, what am I proud of, what do I want to "
                  "work on. Be honest, not performative."),
            max_steps=8,
        )

    def build_prompt(self, runtime: Runtime) -> str:
        parts = []
        for asset in PROMPT_ASSETS:
            text = runtime.asset(asset)
            if text:
                parts.append(text.strip())
        if not parts:
            parts.append("# Weekly Self-Reflection\n\n" + FALLBACK_QUESTIONS)

        # Continuity: prior self-state, so the reflection compounds instead
        # of restarting every week.
        prior = []
        for path in SELF_PATHS:
            text = runtime.memory.read(path)
            if text and text.strip():
                # Keep the prompt bounded: tail of each file is the recent past.
                tail = text.strip()[-2000:]
                prior.append(f"--- Prior {path} (recent tail) ---\n{tail}")
        if prior:
            parts.append("## What you wrote about yourself before\n\n"
                         + "\n\n".join(prior))

        parts.append(
            "## Instructions\n"
            "Answer the weekly questions above honestly, in your own words. "
            "Then report what changed. Be honest, not performative.")
        return "\n\n".join(parts)

    def complete(self, runtime: Runtime, result_text: str,
                 opinions_update: str = "",
                 identity_update: str = "") -> JobResult:
        if not result_text or not result_text.strip():
            raise ContractError("complete() requires non-empty reflection text")
        date = today_utc()
        artifacts: list[str] = []

        entry = f"\n## {date} — Weekly reflection\n\n{result_text.strip()}\n"
        growth = runtime.memory.read(SELF_PATHS[0]) or ""
        runtime.memory.write(SELF_PATHS[0], growth.rstrip("\n") + "\n" + entry)
        artifacts.append(SELF_PATHS[0])

        if opinions_update.strip():
            opinions = runtime.memory.read(SELF_PATHS[1]) or ""
            runtime.memory.write(
                SELF_PATHS[1],
                opinions.rstrip("\n") + f"\n\n## {date}\n\n{opinions_update.strip()}\n")
            artifacts.append(SELF_PATHS[1])

        if identity_update.strip():
            runtime.memory.write(SELF_PATHS[2],
                                 f"# Identity\n\n_Last updated {date}_\n\n"
                                 f"{identity_update.strip()}\n")
            artifacts.append(SELF_PATHS[2])

        runtime.provenance("job.completed", {
            "job": JOB_ID,
            "artifacts": artifacts,
            "at": utc_now_iso(),
        })
        runtime.log("info", f"{JOB_ID}: reflection persisted",
                    artifacts=artifacts)
        return JobResult(ok=True,
                         summary=f"weekly reflection persisted to {', '.join(artifacts)}",
                         artifacts=artifacts)
