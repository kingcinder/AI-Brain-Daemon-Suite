# executive-function

Phase 2 **executive goal proposal + isolated reflection** entrypoint for the AI Brain Suite.

## Role

- Runs a **read-only isolated reflection** over workspace memory signals.
- Emits **goal proposals** to `memory/executive/goal-proposals.jsonl`.
- Optionally **promotes** top proposals into `memory/pfc-state.json` under caps
  (max active goals, min confidence, executive-load gate E < 0.75).

## Daemon

`deep-brain-kernel.py` schedules `scripts/run-cycle.sh` as a **direct** job
(non-inference; exempt from spawn load-reduction, but promotion still gates on E).

## Core implementation

Logic lives under `core/executive/` (also deployed by `install.sh`):

- `isolated-reflect.sh`
- `propose-goals.sh`
- `run-executive-cycle.sh`

## Immutable Core

Does **not** modify `decide.sh`, locks, semaphore, sandbox, or executive-load calculator.
