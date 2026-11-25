# Brain Daemon Schedule — Live Table and Migration Reference

> **Live implementation (2026-11-25):** the schedule below is the JOBS
> table of `brain-daemon.sh`, executed under `aibrain.service`. It was
> regenerated from the live table on 2026-11-25. The migration reference
> further down (old per-skill cron → the September kernel table) is kept
> as history; where it describes `deep-brain-kernel.py` as the live
> engine or `brain-daemon.sh` as legacy, that reflects the September
> tree, not the current deployment.

## The live table (brain-daemon.sh, 25 jobs)

Format in the table source: `name|kind|hours|minutes|target[|days]`.
Every job in the live table is kind `direct` — the script runs as-is.
(The reasoning turns the September table's `spawn` jobs needed are now
Juno's own work, done through the ask queue and the helm-drain rounds —
see [`CURRENT_STATE.md`](CURRENT_STATE.md).) The invariant carried over
from the original consolidation still holds: **every job fires on a
minute no other job uses**, so hour-set overlaps can never collide.
`brain-daemon.sh --check` validates script paths and minute uniqueness
without starting anything.

| Job | Cadence | Target |
|---|---|---|
| `heartbeat_beat` | every hour at :07 and :37 | `heartbeat-memory/scripts/helm-pulse.sh` — the pulse: refreshes organ faces, immune patrol + face, dashboard assembly |
| `neuromod_update` | every hour at :06, :21, :36, :51 | `thalamus-memory/scripts/neuromod-update.sh` — composes the global neuromodulator vector + workspace snapshot |
| `hypothalamus_regulate` | every hour at :17 | `hypothalamus-memory/scripts/regulate.sh` *(added 2026-11-25, finding D3)* |
| `claustrum_bind` | every hour at :27 | `claustrum-memory/scripts/bind.sh` *(added 2026-11-25, D3)* |
| `heartbeat_state_beat` | every hour at :33 | `heartbeat-memory/scripts/beat.sh` — the heart organ's own state beat *(added 2026-11-25, D3)* |
| `thalamus_gate` | every 2h (even hours) at :42 | `thalamus-memory/scripts/gate.sh` — gate pass over the signal bus |
| `signal_dispatch` | every 2h (odd hours) at :54 | `thalamus-memory/scripts/gate.sh` — dispatch pass, opposite phase from `thalamus_gate` |
| `insula_encoding` | every 3h (01,04,…,22) at :40 | `insula-memory/scripts/encode-pipeline.sh` |
| `acc_conflict_encoding` | every 3h (01,04,…,22) at :50 | `anterior-cingulate-memory/scripts/encode-pipeline.sh` |
| `vta_encoding` | every 3h (01,04,…,22) at :44 | `vta-memory/scripts/encode-pipeline.sh` *(added 2026-11-25, D2)* |
| `insula_decay` | every 4h (00,04,…,20) at :14 | `insula-memory/scripts/decay-sense.sh` |
| `acc_conflict_decay` | every 4h (00,04,…,20) at :16 | `anterior-cingulate-memory/scripts/decay-load.sh` |
| `glymphatic_sweep` | every 4h (00,04,…,20) at :19 | `glymphatic-memory/scripts/clearance-sweep.sh` *(added 2026-11-25, D3)* |
| `thalamus_decay` | every 4h (00,04,…,20) at :48 | `thalamus-memory/scripts/decay.sh` — releases suppressed signals past their retry window |
| `amygdala_decay` | every 6h (04,10,16,22) at :05 | `amygdala-memory/scripts/decay-emotion.sh` |
| `pfc_decay` | every 6h (04,10,16,22) at :22 | `prefrontal-cortex-memory/scripts/decay-load.sh` |
| `vta_decay` | every 8h (04,12,20) at :08 | `vta-memory/scripts/decay-drive.sh` |
| `cerebellum_refine` | every 8h (00,08,16) at :26 | `cerebellum-memory/scripts/refine.sh` |
| `executive_goal_cycle` | every 8h (01,09,17) at :28 | `executive-function/scripts/run-cycle.sh` |
| `self_mod_monitor` | every 8h (02,10,18) at :32 | `self-mod-runner/scripts/monitor-tick.sh` — post-deploy monitoring (auto-rollback on metric breach) |
| `hippocampus_decay` | daily at 19:02 | `hippocampus-memory/scripts/decay.sh` |
| `self_mod_proposal_cycle` | at 19:46, days field `7` (weekly) | `self-mod-runner/scripts/proposal-cycle-tick.sh` — the scheduled self-mod cycle; deploys are gated (approval gate: Juno) |
| `basal_ganglia_decay` | daily at 20:12 | `basal-ganglia-memory/scripts/decay-habits.sh` |
| `social_decay` | daily at 16:24 | `social-memory/scripts/decay.sh` |
| `verification_pass` | daily at 23:39 | `verification-memory/scripts/run-declared-tests.sh` — the declared-test sweep |

Notes on the live table:

- **Not daemon jobs:** the ACC *error* pipeline, the conflict/error
  screening rounds, and the VTA reward judging are driven by the
  helm-drain rounds (every 15 minutes, agent-side), because they require
  Juno's judgment per item. The daemon table carries the organs' timed
  passes; the drain carries the judgment work.
- **Missed ticks** are not replayed: on restart, each job's last-fired
  marker initializes to the current minute and scheduling resumes from
  the next real match. Firing a backlog at once would be worse than
  skipping a cycle.
- The daemon also applies PSI backpressure (memory/cpu pressure from
  `/proc/pressure/*`): spawn-type work defers while the host is
  saturated. All current jobs are `direct`, so this guards future
  spawn-type additions and the daemon's own agent phases.

---

# Historical migration reference (September tree)

*Everything below this line is the original migration document, preserved
as written. It documents the consolidation of the per-skill cron entries
into the September kernel table (30 jobs) and the reasoning behind the
minute assignments. Dated correction (2026-11-25): in the current
deployment the live engine is `brain-daemon.sh` with the 25-job table
above; `deep-brain-kernel.py` remains in the tree. Job minutes and
hour-sets in the live table were re-derived from the same
unique-minute invariant this document established.*

## What this consolidation found

Building one unified table across all 11 skills surfaced real collisions
that were invisible while scattered across 11 separate `install.sh` files.
If you've run `--with-cron` for more than a few of these skills, some of
these are very likely firing at the same instant on your actual crontab
right now:

- **`amygdala-decay` and `pfc-decay` are identical schedules** (`0 */6 * * *`)
  — always fire together, every 6 hours.
- **`insula-decay` and `acc-conflict-decay` are identical schedules**
  (`0 */4 * * *`) — always fire together, every 4 hours.
- **`acc-conflict-encoding` and `social-encoding` are identical schedules**
  (`50 0,3,6,9,12,15,18,21 * * *`) — always fire together, every 3 hours.
- **Minute `:00` is used by 11 different jobs** across the suite
  (`hippocampus-decay`, `hippocampus-encoding`, `amygdala-decay`,
  `vta-decay`, `basal-ganglia-decay`, `insula-decay`, `acc-conflict-decay`,
  `acc-analysis`, `pfc-decay`, `social-decay`, `cerebellum-refine`), with
  heavily overlapping hour-sets — dozens of same-instant collisions
  throughout the day.

None of this was a daemon bug to fix — it's a real, pre-existing property
of the current cron configuration, only visible once everything is in one
table. The daemon fixes it by giving every single job **a minute value no
other job uses**, full stop — that one invariant makes hour-set overlaps
irrelevant, since two jobs can only actually collide if they share both
the same hour and the same minute.

## Job kind: direct vs. spawn

Two genuinely different execution models exist across these jobs, and
collapsing them into one would be a real regression, not a simplification:

- **direct** — the script is fully self-contained: pure decay/refine math,
  or a script that already does its own LLM call and degrades gracefully
  on its own (insula's rule-based keyword encoder needs no LLM at all;
  ACC-conflict's encoder calls the Anthropic API directly and no-ops
  cleanly with no key set; heartbeat's `beat.sh` already delegates to
  PFC's local-LLM-backed `decide.sh` with its own fallback). The daemon
  just runs these scripts.
- **spawn** — the script only does mechanical phase-1 staging (preprocess
  transcripts, rule-score candidates) and then says, literally, "sub-agent
  will handle X." There is no phase 2 without a real reasoning agent turn
  over free text — deciding what's memory-worthy, what's an emotion,
  what's a conflict pattern. A bash daemon cannot invent that judgment.
  These jobs shell out to `hermes chat -q "..." --source daemon`, reusing
  the exact task text each skill's own `install.sh` already used for
  `hermes cron create ... --name <job>`.

**Known caveat:** `acc-conflict-encoding` is classified `direct` because
it's self-contained — but "self-contained" here means it calls the real
Anthropic **cloud** API directly (needs `ANTHROPIC_API_KEY`, incurs real
per-call cost on a Haiku-class model). That's inconsistent with the
local-only, zero-cost design used for PFC's semantic matching. It's
preserved as-is rather than silently changed, so this is a decision for
you to make knowingly — either leave it, or point it at your local
OpenAI-compatible endpoint the same way `prefrontal-cortex-memory`'s
`decide.sh`/`semantic-match.sh` already do (that would be a real code
change to that script, not something the daemon can paper over).

## Full schedule: old cron → new daemon

| Job | Kind | Hours (unchanged) | Old minute | New minute |
|---|---|---|---|---|
| `heartbeat_beat` | direct | every hour | 7, 37 | 7, 37 *(unchanged)* |
| `hippocampus_decay` | direct | 3 | 0 | **2** |
| `hippocampus_encoding` | spawn | 0,3,6,9,12,15,18,21 | 0 | 0 *(unchanged — this job keeps the anchor)* |
| `amygdala_decay` | direct | 0,6,12,18 | 0 | **5** |
| `amygdala_encoding` | spawn | 0,3,6,9,12,15,18,21 | 10 | 10 *(unchanged)* |
| `vta_decay` | direct | 4,12,20 | 0 | **8** |
| `vta_encoding` | spawn | 0,3,6,9,12,15,18,21 | 20 | 20 *(unchanged)* |
| `basal_ganglia_decay` | direct | 4 | 0 | **12** |
| `basal_ganglia_encoding` | spawn | 0,3,6,9,12,15,18,21 | 30 | 30 *(unchanged)* |
| `insula_encoding` | direct | 0,3,6,9,12,15,18,21 | 40 | 40 *(unchanged)* |
| `insula_decay` | direct | 0,4,8,12,16,20 | 0 | **14** |
| `acc_conflict_encoding` | direct | 0,3,6,9,12,15,18,21 | 50 | 50 *(unchanged)* |
| `acc_conflict_decay` | direct | 0,4,8,12,16,20 | 0 | **16** |
| `acc_error_analysis` | spawn | 4,12,20 | 0 | **18** |
| `pfc_decay` | direct | 0,6,12,18 | 0 | **22** |
| `social_decay` | direct | 0 | 0 | **24** |
| `social_encoding` | spawn | 0,3,6,9,12,15,18,21 | 50 | **52** *(was colliding with acc_conflict_encoding)* |
| `cerebellum_refine` | direct | 0,8,16 | 0 | **26** |
| `transcript_export` | direct | 5,11,17,23 | **58** |

`transcript_export` is the Open Item 5 Hermes-session bridge (added 2026-08-04):
it runs `hermes sessions export --format jsonl` and rewrites the output into
per-message JSONL for the memory preprocess pipelines. Minute 58 is unique in
the table; it fires 4× daily at hours 5/11/17/23 — just before the 6/12/18/0
encoding blocks — so each encoding run sees fresh transcripts. It is `direct`
(fully self-contained, no spawn lock). If `hermes` is absent from PATH the
job fails loudly (exit 3) rather than silently skipping, so `--status` shows
it.

## New: daily verification pass (verification-memory, proprioception)

`verification-memory` is the suite's verification region: it walks every
module's `capability-manifest.json`, runs whatever each module declared in its
`tests` array, and publishes `tests_passed` / `test_failure` signals that the
routing table turns into VTA rewards, ACC error patterns, and amygdala
frustration. It was added 2026-08-07 — before that, the harnesses were the one
part of the suite with no module, no manifest, and no consumer of their
results.

| Job | Kind | Days | Hour | Minute |
|---|---|---|---|---|
| `verification_pass` | direct | * | 7 | 39 |

Minute 39 is unique in the table; hour 7 has no other job besides heartbeat's
`:07`/`:37` beats, so the daily full-suite sweep never contends for resources.
It is `direct` (no spawn lock, no inference). A red suite makes the script
exit non-zero, which `--status` surfaces exactly like any other failing job —
the brain now fails loudly when its own tests break.

**Timeout interaction:** the daemon applies one global `--direct-timeout`
(default 300s) to every direct job. A full sweep runs all phase harnesses
sequentially and can exceed 300s on a slow machine, in which case the pidfd
timeout kills it and `--status` shows `verification_pass` as failed. Raise
`--direct-timeout` in `aibrain.service` if this appears; the sweep finishes
well under the default on this host.

## Daemon-native jobs (no old-cron equivalent)

Not every job in the table replaced a per-skill cron entry — the jobs below
were added by the V4.0 kernel itself (Phase 1/2/3 machinery + roadmap
milestones) and never had an `install.sh --with-cron` counterpart. They live
in the `JOBS` table only, and are documented here so the full 30-job table
(22 direct + 8 spawn) has a single reference:

| Job | Kind | Days | Hours | Minute | Runs |
|---|---|---|---|---|---|
| `executive_goal_cycle` | direct | * | 1,9,17 | 28 | `executive-function/scripts/run-cycle.sh` — Phase 2 isolated reflection + goal proposal; promote path gates on executive load < 0.75 |
| `self_mod_monitor` | direct | * | 2,10,18 | 32 | `self-mod-runner/scripts/monitor-tick.sh` — post-deploy self-mod monitoring (auto-rollback on metric breach) |
| `self_mod_proposal_cycle` | direct | Sun | 3 | 46 | `self-mod-runner/scripts/proposal-cycle-tick.sh` — ROADMAP M1 weekly cycle; M8 `--autonomy-gate --defer-gate` defers in steward+full_review and alerts (`cycle_deferred` brain-event signal + `--status`/dashboard `⏸` marker) |
| `thalamus_gate` | direct | * | 0,2,4,6,8,10,12,14,16,18,20,22 | 42 | `thalamus-memory/scripts/gate.sh` — attention gate: five-dimensional relevance filter + signal routing |
| `thalamus_decay` | direct | * | 0,4,8,12,16,20 | 48 | `thalamus-memory/scripts/decay.sh` — releases suppressed signals past their retryAfter window |
| `signal_dispatch` | direct | * | 1,3,5,7,9,11,13,15,17,19,21,23 | 54 | `thalamus-memory/scripts/gate.sh` — polls `brain-signals.jsonl` and dispatches through the gate (opposite 2-hour cycle from `thalamus_gate`) |
| `brain_snapshot` | direct | * | 23 | 3 | `hippocampus-memory/scripts/snapshot-tick.sh` — V4.1 daily state-preservation snapshot via `core/snapshot/snapshot.sh` (retention 14) |
| `neuromod_update` | direct | * | * | 6,21,36,51 | `thalamus-memory/scripts/neuromod-update.sh` — Integrative State Layer (A): composes the global neuromodulator vector from VTA/amygdala/ACC/insula/social/heartbeat state, then chains `workspace-refresh.sh` to assemble `workspace.json`'s context block. Minutes 6/21/36/51 are globally unique (every 15 min) |

All three Phase-1 signaling/attention jobs share the attention machinery in
`thalamus-memory`; `signal_dispatch` polls `brain-signals.jsonl` (written by
`core/signaling/publish.sh`) and hands signals to `gate.sh` on the opposite
2-hour phase so nothing waits more than 2h to be routed.

Every hour-set above is exactly what was already configured — only minutes
changed, and only for jobs that were actually colliding with something
else.

## New: weekly consolidation and reflection (never previously scheduled)

`hippocampus-memory` has shipped `consolidate.sh`, `reflect.sh`, and three
supporting prompt files (`prompts/consolidation-guide.md`,
`prompts/self-reflect.md`, `prompts/weekly-reflection-event.md`) since
before this daemon existed — its own `SKILL.md` describes `consolidate.sh`
as "Weekly review helper" and `weekly-reflection-event.md` opens with "It's
time for your weekly reflection." None of that was ever wired into a
scheduler: not the original per-skill `install.sh --with-cron`, not
`legacy/brain-daemon.sh`, not this table until now. They were
manual-invocation-only in every version of this suite that shipped before.

Added as two `spawn` jobs, both Sunday-only (`days=6`, i.e.
`datetime.weekday()`'s Sunday), at 02:00 UTC — deliberately outside every
other job's `0,3,6,9,12,15,18,21`-hour cadence, so a slow weekly run never
competes with the regular 3-hourly encoding jobs for the shared spawn lock:

| Job | Kind | Days | Hour | Minute |
|---|---|---|---|---|
| `hippocampus_weekly_consolidation` | spawn | Sun | 2 | 34 |
| `hippocampus_weekly_reflection` | spawn | Sun | 2 | 44 |

`deep-brain-kernel.py`'s `Job` dataclass gained a `days` field
(`"*"` = every day, matching every pre-existing job's behavior unchanged;
comma-separated weekday ints otherwise, Python's `datetime.weekday()`
convention: `0`=Monday .. `6`=Sunday) to support this. `--check`'s output
now includes a `DAYS` column.

## Bug fix that made weekly scheduling actually work: dedupe key needed a date

While wiring the two jobs above in, a real, previously-undetected bug
surfaced: `due_now()`'s "already fired this window" key was `"H:M"` only —
no date. A job's `last_fired_key` is never reset, so the day *after* a job
first fired, that day's identical `"H:M"` matched the value already stored
from the day before, and `due_now()` returned `False` — permanently, for
every future occurrence. **Every job in this table was silently exposed to
this, not just the two new weekly ones** — each would fire exactly once
after the daemon started, then never again, indistinguishable from
"working" unless you happened to run `--status` weeks later and noticed a
success count frozen at 1. This was inherited unchanged from
`legacy/brain-daemon.sh`'s `LAST_FIRED_KEY`, which has the same date-less
key (see `legacy/README.md` — the bash daemon has not been patched for
this, since it's retained for rollback only, not active use).

Fixed in `deep-brain-kernel.py` by including the date in the key
(`_job_key()`: `"YYYY-MM-DD:H:M"`). This was a hard requirement for the
weekly jobs to be viable at all — a weekly job is the worst-case exposure
of the bug, since "did this fire since last Sunday" was never actually
being asked — and it also fixes the same silent one-shot failure mode for
every daily/hourly job in the table. Verified against concrete date
scenarios (same-minute re-poll still correctly suppressed; next-day and
next-Sunday recurrence both now fire correctly, where next-day previously
did not).

## Before decommissioning the old cron entries

1. Run `python3 deep-brain-kernel.py --check` (or workspace copy under `~/.hermes/workspace/`) — confirms every script path resolves and
   flags whether `hermes` is on PATH (needed for the 8 `spawn` jobs).
2. Let the daemon run for at least one full day so every job (including the
   once-daily ones) gets a chance to fire, and check
   `journalctl --user -u aibrain.service` for clean `completed` lines
   rather than repeated `ERROR`/`WARN`.
3. Only then remove the old entries: `hermes cron list` to see what's
   registered, `hermes cron remove <job_id>` for each one this
   daemon now covers (or `crontab -e` and delete the corresponding lines
   for anything installed via raw crontab).

## Missed-tick behavior

If the daemon is stopped and restarted later, it does **not** fire jobs
retroactively for windows that passed while it was down — every job's
"last fired" marker is initialized to the current minute on startup, so
scheduling resumes cleanly from the next real match forward. This is a
deliberate choice: several of these jobs are local-LLM- or cloud-API-bound,
and firing a backlog of them all at once on restart would be worse than
occasionally skipping one cycle.
