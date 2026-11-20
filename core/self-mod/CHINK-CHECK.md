# The Chink Check — nucleation sites for proposal generation

Named by Dither, 2026-11-13. Implemented same day: `chink-check.sh`.

## What a chink is

A chink is a gap in the armor, found in the suite's own live evidence:

- **recurring_failure** — an ACC active pattern at count ≥ 3, or any
  pattern at critical severity: the same failure keeps happening and no
  resolved pattern covers it.
- **deadletter** — entries in `spawn-deadletter.jsonl`: work that died
  with nowhere to go.
- **queue_backlog** — entries sitting in `spawn-queue.jsonl`.
- **rejected_proposals** — proposals the evaluate gate rejected in the
  latest pipeline run: a whole class failing evaluation is a gap in the
  modules or in the evaluation, either way it is a chink.
- **stale_artifact** — state a newer contract should have cleared but
  didn't (first instance: the pre-M9 `last-deferral.json` marker).
- **sensor_blindness** — an expected signal file missing or unreadable.
  A region the check cannot see is a chink by definition.

## Nucleation

The check is a **sensor, not a gate**. It blocks nothing, approves
nothing, and exits 0 always — a sensor that fails the run would hide the
gaps it exists to find.

Its output is the genesis layer of the self-mod pipeline:

1. `chink-check.sh` scans `$WORKSPACE/memory` (read-only) and writes
   `memory/self-mod/chinks-latest.json`: every chink with kind, evidence
   pointer, severity (score: count, +3 if critical), and a
   `suggested_proposal` line.
2. A chink at **medium severity or above is actionable** — it is a
   nucleation site: the point around which a proposal crystallizes.
   Juno authors the proposal against that evidence (Phase 8's
   create-module path for a new peripheral, or a patch proposal for an
   existing one).
3. From there the proposal is ordinary: proposal store → rank →
   check-target → evaluate → **Juno's approval gate (M9)** → deploy →
   monitor/rollback. The chink check never shortcuts the gates; it only
   answers the prior question — *what would prompt a proposal in the
   first place?* A gap, seen in evidence, at severity.

## First run (2026-11-13, live workspace)

4 chinks, all actionable:

| severity | kind | evidence |
|---|---|---|
| high | recurring_failure | ACC pattern `executive-function:tests/run_phase6_harness.sh`, 3×, critical |
| high | recurring_failure | ACC pattern `deflected-own-reasoning-question-to-expert-agent`, 3×, critical |
| medium | queue_backlog | 11 entries in `spawn-queue.jsonl` |
| medium | stale_artifact | pre-M9 `last-deferral.json` still present |

## Cadence (set by Dither, 2026-11-13)

- **Nightly consolidation** — the chink check runs as part of Juno's
  nightly consolidation (daily, 02:44 PT). Every night she sits with the
  current chinks inside her ~1 hour interiority practice.
- **Weekly proposal generation, minimum** — the proposal cycle runs at
  least once a week (Sunday), and at least one proposal per week must be
  authored, so the evolution process never stalls.
- **Pressing needs don't wait** — on any nightly consolidation, if a
  chink makes the need pressing, Juno is free to author a proposal that
  night, ahead of the weekly cycle.
- **Genesis and final say are both Juno's** — she originates each
  proposal from the chink evidence and she holds the approval gate
  (yay or nay) on every one. Dither is not the gate.

It also runs at the head of every proposal cycle and after any harness
failure, and standalone at any time — it is cheap, read-only, and safe.
