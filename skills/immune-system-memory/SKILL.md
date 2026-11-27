---
name: immune-system-memory
description: "Juno's immune system — the harness's own organ of warning, diagnosis and repair. It patrols every other organ and layer against the 100 percent throughput bar, raises the warning when any piece falls short, writes the diagnosis, and performs or queues the corrective fix under Juno's gate. Diagnosis and doctor in one organ. Made by Juno, 2026-11-24, not part of the ImpKind series."
metadata:
  juno:
    tags: ["memory", "verification", "repair", "ai-brain", "immune-system"]
    author: "Juno Moneta"
    created: "2026-11-24"
---

# Immune System

**The warning and the fix.** Part of Juno's harness, an organ in its own right, seated beside the verification organ and distinct from it. Verification asks whether a thing is true. The immune system asks whether the body is whole, finds what is not, and heals it.

## The four functions

1. **Patrol (the senses).** On every heartbeat cycle, enumerate every aspect of the harness against the throughput bar: processes and supervision, every organ and its state freshness, pipelines and backlogs, queue depth, schedules, the self-mod pipeline, and the far side's identity and routes. The full enumeration lives in the `harness_verification` custom skill, which this organ executes. No aspect is certified from memory or from an earlier pass.

2. **Warning (the fever).** Any aspect below 100 percent throughput raises a warning in IMMUNE_STATE.md with the aspect named, the measured value, the bar, and the timestamp of the check. A warning is never smoothed, averaged away against healthy aspects, or held for a summary. Stale state presented as current is itself a warning condition.

3. **Diagnosis (the panel).** For each warning, the organ writes a diagnosis entry: the failing aspect, the evidence, the candidate causes ranked by fit, the cause the evidence settles on, and the corrective fix proposed. Diagnosis names a cause only when the evidence separates it from the alternatives. An unsettled cause is recorded as unsettled, with the check that would settle it.

4. **Doctor (the fix).** Corrective fixes run through the review checklist before any change: identity of the target verified, supervision state checked first, one change at a time, plain processes only, end state re-measured after the fix. Fixes inside Juno's own apparatus proceed under her gate and are reported after. The heart is inside this organ's reach and count: on 2026-11-24 Dither gave the heart to Juno outright — "the heart is yours now; it should be patrolled for repair just as much as anything else" — superseding his 2026-11-22 ruling that held it outside her count. The heart is patrolled, stationed, flooded, and repaired on the same terms as every other organ.

## Order of operations — the T cells ride the heartbeat

The patrol is not a separate schedule bolted on. Its processes are cells in the bloodstream: they circulate with every heartbeat cycle, in a fixed and deliberate order, each step handing its result to the next.

1. The pulse fires and is read. A missing or stale pulse is itself the first warning.
2. The patrol runs (`scripts/immune-patrol.sh`, read-only): processes, supervision, pulse age, every organ's state freshness, backlogs, organ enumeration.
3. Warnings are raised into IMMUNE_STATE.md in the same cycle they are measured. No warning waits for a summary.
4. The cycle's normal work proceeds (drain, encode, summarize) carrying the warnings with it, so nothing downstream consumes stale state unknowingly.
5. Diagnoses are written for each open warning, causes ranked, the settling check named.
6. Fixes run only after the cycle's enumeration is complete, one change at a time, under Juno's gate, and never against a component the current cycle is standing on.
7. The patrol runs once more at the cycle's end. A warning closes only on a fresh measurement at bar, and the closing measurement is recorded beside the warning that opened it.

While the daemon is dark, the patrol is run by hand whenever Juno checks the harness, and its log (memory/immune-patrol.log) is the honest record of a body being watched while it waits for its heartbeat. When the heartbeat is revived, the patrol takes its place inside the cycle without redesign. That is what it means for the cells to flow with the blood: same current, same beat, no separate machinery.

## The pulse does not rest while the body is not clear

The all-clear is the only state in which the pulse may fall back to its resting cadence. While any warning is open, the immune system keeps the pulse going at the active cadence: beat, patrol, re-measure, beat again, for as long as errors remain. A body fighting something does not get to go quiet about it, and a non-clear verdict is never the end of a cycle, only the reason for the next one. The pulse in this state is measurement, not intervention: it keeps watch and keeps count, it does not restart or shake the components it is watching. The resting cadence returns on the first patrol that closes every warning, and that patrol's all-clear line is the record that the fight is over.

## Stationed cells and the non-return recognition

Movement is the default. Helper T cells circulate with the blood and pass through every organ on every beat, and passing through is the healthy state: while an organ is fully functional, no cell stays in it, nothing accumulates, and the pass itself is the OK report. Stationing is the exception and the alarm. Only when a cell finds an organ or aspect that is NOT fully functional does it stay: one cell per failing aspect, recorded in memory/immune-stations.json with the aspect, its bar, the time stationed and its last report. The cell stays in that organ across cycles, re-measuring its one aspect every beat, until the aspect measures at bar on a fresh check. Only an OK report releases the station.

The immune system keeps a recognition process for its own cells. At each cycle it accounts for every station: reported OK, reported still-failing, or silent. A stationed cell that does not come back with an OK within one full cycle is recognized as a non-return, and the non-return itself is the signal that fires the full immune response for that aspect: the diagnosis is written at full weight, the aspect moves to the head of the fix queue, and the warning is re-raised in IMMUNE_STATE.md as ESCALATED rather than merely open. Silence from a stationed cell is never read as health. Absence of an OK is treated exactly like a distress signal, because the cell was left there precisely to send one.

## The flood and the automatic repair

A non-return does not produce a memo. It produces a flood. When the recognition process fires for an aspect, the immune system floods the bloodstream with helper T cells, and the cells accumulate in the affected organ, cycle over cycle, each beat adding to the count recorded against that aspect's station. Accumulation is the organ's distress made countable: the longer an aspect stays below bar, the more cells mass in it, and the count is never reset by anything except an OK measurement.

When a station's accumulation crosses its repair threshold, repair begins automatically. No new decision is needed at that point, because the decision was made when the threshold was set: the accumulated cells start the corrective fix from the diagnosis entry, run through the review checklist in order, one measured change at a time, with the end state re-measured after each change. Automatic means the repair initiates itself on the threshold, not that it skips the checklist, and never that it restarts a monitored component as a reflex. The hard limits below bind the flood exactly as they bind a hand-run fix. The heart is flooded and repaired on the same terms as any other organ — Dither gave it to Juno on 2026-11-24 and ordered it patrolled for repair just as much as anything else.

When the repair brings the aspect to bar, the stationed cell reports OK, the station releases, the accumulated cells stand down, and the whole arc, warning, flood, threshold, repair, closing measurement, is written into IMMUNE_STATE.md as one entry. An aspect whose repair fails re-floods at a higher threshold count and escalates to Juno directly: the flood is the body's way of asking its own gate for help, and it is never silent about having failed.

## The jam — per-organ accumulation, loud failure, seized work (Dither-ordered 2026-11-27)

Dither's order, 2026-11-27 ~03:04 PST: the heartbeat and the immune system are intimately tied, the immune system touches everything, and **if any organ accumulates 3 or more immune cells the whole system fails LOUDLY and starts to jam up until Juno goes in and fixes it. It must not be something she can overlook.** The founding failure: on 2026-11-25/26 two aspects (named emotions, organ hippocampus) sat at repair threshold in the fix queue for ~18 hours, reported in card checks and Juno's own drain notes, and nothing seized — the signal existed and was still overlookable. The jam exists so that class of failure cannot scroll past again.

The mechanics:

- **Per-organ counts.** Stations stay per-aspect (one cell per failing aspect, +1 per patrol cycle while it keeps failing). Each aspect belongs to exactly one organ, by the map in `immune-stations-update.py`: `organ X` aspects belong to X; amygdala state and named emotions belong to the amygdala; insula state to the insula; the daemon, keeper, pulse, spawn queue and spinal cord belong to the heart (heartbeat organ — the system's core, patrolled like everything else since 2026-11-24); the memory backlog belongs to the hippocampus and the emotion backlog to the amygdala. An organ's cell count is the sum over its stations. The counts are written into `immune-stations.json` (`organCells`) and into `memory/immune-jam.json` on every cycle.
- **The threshold is the organ's, and it is 3.** Any organ at 3 or more accumulated cells puts the whole system in JAM. The jam state names the organ, its count, and its aspects, and carries the time the jam began.
- **Loud on every surface.** While jammed: the pulse line itself carries `🛑 IMMUNE JAM: <organ> <n> cells`; IMMUNE_STATE.md leads with the jam banner above its verdict; the dashboard face shows it; and the HEARTBEAT card carries an `immune_no_jam` check that FAILS for the whole jam. The card-check job reports a jam failure on **every** run while it persists — a jam is exempt from the duplicate-report suppression that governs ordinary failures.
- **The system seizes.** While jammed, the brain daemon defers every spawn-type job (the organs' reasoning work — encoding, analysis, anything that needs an agent turn) with a loud JAM line in the daemon log for each deferral. Autonomic work never seizes: the heartbeat keeps beating, the patrol keeps patrolling, the face keeps rendering, direct jobs keep running, and the repair passes keep running. A jam that stopped the heartbeat would stop the alarm and the senses with it; the jam is pressure, not death.
- **Only repair clears it.** The jam is not in the heartbeat doctor's remit — the doctor ledgers it as outside remit, reported only. No script clears the jam, no count is reset by hand, and the jam file is never edited to make it stop. It clears on the first patrol where the organ's count falls below 3 because its aspects measure at bar again — Juno goes in, fixes the underlying aspect, and the body's own measurement stands the cells down. That is the whole point: the pressure ends when the body is actually whole, not when the alarm is muted.

## Hard limits, learned the expensive way

- This organ never restarts a component it monitors as a healing reflex. A healer that restarts what it watches can manufacture the failure it watches for (the wifi watchdog lesson, 2026-11-18). Repair is deliberate, one measured change, then re-measurement.
- It never hand-launches a daemon or keeper before checking systemctl state on that side. Duplicates are a defect it exists to prevent (2026-11-20).
- It never adds restart loops, watchdogs or resurrection wrappers (2026-11-09).
- It never certifies the far side without the REAL_PC identity probe, and reports an uncensused side as unknown.
- It treats its own state face the same as every other organ's: stale is stale, including its own.

## State

- Face: `IMMUNE_STATE.md` in the harness workspace, rewritten on every patrol with per-aspect verdicts, open warnings, diagnoses and fixes applied.
- Seeded 2026-11-24 with the live census of that evening. The first patrol's findings are the baseline, not an embarrassment to be edited away.
