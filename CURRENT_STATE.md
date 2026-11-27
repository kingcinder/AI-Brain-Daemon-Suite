# Current State — Verified 2026-11-25 (PST)

This file records the state of the **live deployment** of the AI Brain
Daemon Suite as measured on 2026-11-25. It is a dated snapshot, not a
living promise: later states supersede it, and each claim below names how
it was measured.

The deployment: the suite runs as the agent Juno's own harness, in her
workspace, supervised by systemd units whose sources ship in `systemd/`
(`aibrain.service` → `brain-daemon.sh`; `helm-keeper.service` →
`bin/helm-keeper`). A second, smaller copy of the harness exists on the
operator's PC (15 organs, its own daemon/keeper under a session parent);
it is a far-side copy, not a second live instance on the same state.

## Verification method

A full verification pass was run 2026-11-25, 03:21–03:36 PST, under the
suite's verification discipline:

- Acceptance criteria were written **before** inspecting anything.
- Every section was verified by enumeration (organs counted one by one,
  queues measured, stamps read), not by impression.
- An adversarial second pass hunted for the failures least wanted.
- Verdicts come from live measurement only: process counts, state-file
  timestamps, queue depths, bus/checkpoint line counts, and page content
  checked on all three dashboard surfaces (assembled file, served page,
  delivered copy).

Final re-pass (~03:35 PST): **heartbeat card 11/11 PASS**; heartbeat
regression suite then at 54/54, extended the same morning to **58/58**
(see "Repairs after the pass").

## What measured at its bar

- **Processes/supervision.** Exactly one top-level brain-daemon and one
  helm-keeper (counted by exact argv match among top-level processes
  only — both programs spawn children). Both systemd units enabled and
  active. Dashboard server answering on the workspace loopback port;
  dashboard tunnel process alive.
- **Organs.** 19/19 skill directories present, each organ's primary state
  file fresh within its cadence. The two ACC organs' states were minutes
  old and consulted 0.0h before the final check. Amygdala verified in both
  layers (dimensions + named emotions). Insula channels read individually.
- **Pipelines/backlogs.** Helm ask queue depth 0, deadletter 0. Gate bus
  fully consumed (checkpoint == bus lines, 626/626 at pass time).
  Pending memory/emotion/sense stores empty — no stuck flows.
- **Schedules.** The operational cadence around the harness all enabled
  and firing: helm drain 15m, conversation-wire sweep 15m, heartbeat card
  check 30m, telemetry refresh 5m, presence wake 4h, standing-cards backup
  1h, plus a 5m route keepalive that had been lost in a past deployment
  and was recreated during the pass.
- **Self-mod.** 17 proposals on the ledger: 9 deployed, 5 rejected,
  2 rolled back, 1 ranked; no stuck drafts. Autonomy state
  `steward_mode`, auto-deploy off. The approval gate holder is Juno
  (operator's order, 2026-11-13).
- **Far side.** The operator-PC copy's daemon and keeper run under a
  session parent (its systemd units are inactive there). Its desktop
  receives the hash-verified dashboard build, ACC sections included.
- **Language.** No banned canned phrasing anywhere in harness-facing
  texts.

## Findings and fixes (D1–D6)

### D1 — Errors and Conflicts not reporting (the presenting complaint)

Both ACC organs were processing — states fresh, faces current — but the
dashboard carried nothing from either. Cause: the dashboard is assembled
from per-organ fragments by the shared builder, whose registry expects
fragment ids `acc_error` (order 50) and `acc_conflict` (order 60); **no
ACC fragments existed**, and both ACC skills' `generate-dashboard.sh` were
pre-fragment *monoliths* that rewrote the whole dashboard file, racing
the fragment builder (three different file sizes observed within the
hour). Fix: the monoliths were backed up and replaced with fragment
writers in the sibling idiom (own state only, always write, then call the
shared builder). Verified afterward in the assembled dashboard, the
served page, and the delivered desktop copy. Regression guards F10 added.

### D2 — VTA reward intake frozen

`pending-rewards.json` had been untouched since 2026-11-15: 133 entries,
oldest 233h. The encode pipeline's agent phase had **no driver anywhere**,
and a helper script read a dead transcript path. All 133 entries were
judged individually: every one was worker boilerplate (99 execution-pass
notifications, 34 cron reports) — zero genuine reward moments. Encoded 0,
rejected 133, pending cleared. The agent phase is now driven permanently
by the helm-drain rounds (step 7b), a `vta_encoding` job was added to the
daemon table (every 3h at :44), and the helper honors the transcript-bridge
corpus path.

### D3 — Four organ passes had no schedule

Hypothalamus `regulate`, claustrum `bind`, the heartbeat organ's `beat`,
and the glymphatic `clearance-sweep` existed as scripts but had no daemon
jobs; their states advanced only when something else happened to run them.
Five jobs were added to `brain-daemon.sh` (the four above plus
`vta_encoding` from D2): `hypothalamus_regulate` hourly :17,
`claustrum_bind` hourly :27, `heartbeat_state_beat` hourly :33,
`vta_encoding` every 3h :44, `glymphatic_sweep` every 4h :19. The daemon
was restarted once via systemd; all passes proven rc=0 with states
advanced. The full live table is in
[`BRAIN_DAEMON_SCHEDULE.md`](BRAIN_DAEMON_SCHEDULE.md).

### D4 — Glymphatic sweep orphan noise

The clearance sweep reported 9 "orphaned" stores per run; most had real
readers that were simply never registered in the flow registry, and
backup artifacts matched no internal pattern. Fix: 6 flows registered in
`core/gate/flows.json` with their real readers (named-emotions,
encoded-emotions, immune-fix-queue, immune-stations, pending-clean,
pending-held); `*.backup*` / `*.prepush*` added to internal stores. The
next sweep's notes were empty — no orphans, no overstays.

### D5 — Far-side spawn queue growing with no drainer (resolved same day)

The operator-PC copy's spawn queue held 563 entries (oldest ~16 days,
growing ~53/day): its daemon enqueues tasks only Juno can answer, and
nothing drained that copy. Left open by the verification pass as the
operator's call. **Resolved 2026-11-25 ~04:29 PST:** the queue was
censused (567 entries by then), archived to a dated `.jsonl` on that
machine with SHA-256 verification (archive and source hashes matched),
and the live queue truncated to 0 and verified — all behind the
connection identity guard.

### D6 — ACC screening counters never incremented

`totalScreened` / `totalAnalyzed` in the error organ's state were 0 while
screening ran every drain round (110+ errors logged historically): no
writer ever incremented either counter. Fix: the encode pipeline now
increments both, at the points where the counts are true. No backfill —
historical screening was never recorded, and invented numbers would be
worse than the gap.

## Repairs after the pass (same morning)

- **Queue-check false failure (~03:39–03:44).** The card's queue check
  read a stale pulse-log snapshot and reported a failure while the live
  queue held only fresh asks, which were answered by hand and verified.
  The check now measures the **live queue**: PASS if empty, or if the
  oldest unacked ask is younger than one drain cycle (15 minutes). The
  card's bar was updated to match. Regression section F11 added; suite at
  58/58.
- **Harness outage and repair (~05:24–05:44).** The daemon and keeper
  both received SIGTERM at 05:24:57 (cause unknown) and the dashboard
  server died in the same window. The doctor restarted daemon and keeper
  within its remit (both active, exactly one top-level process each).
  The tunnel then failed for a subtler reason: the reverse tunnel was
  alive but its target — the dashboard server — was down, so the
  operator-side port answered nothing. The server was restarted by hand;
  all three surfaces verified serving again; card back to 11/11 PASS,
  with one hand-fired pulse to clear a pulse-freshness failure. This
  outage is the direct evidence for residual note 1 below.

## The heartbeat card (11 checks)

The card is the standing health definition for the live deployment. A
checker runs it every 30 minutes; it parses the card's own check names,
and an unknown check name fails rather than passing silently.

| Check | Bar |
|---|---|
| `pulse_fresh` | Last helm pulse line ≤ 35 minutes old |
| `organs_present` | 19/19 organs present (the heart is inside the count — ruling of 2026-11-24) |
| `queue_drained` | Live ask queue empty, or oldest unacked ask < 15 minutes (one drain cycle) |
| `keeper_ok` | Keeper reported healthy in the last pulse |
| `single_daemon` | Exactly one top-level brain-daemon process |
| `single_keeper` | Exactly one top-level helm-keeper process |
| `immune_face_fresh` | Immune system's public face ≤ 65 minutes old |
| `immune_queue_clear` | Immune fix queue empty |
| `acc_consulted_fresh` | Error organ's `lastConsultedAt` ≤ 26 hours old |
| `conflict_consulted_fresh` | Conflict organ's `lastConsultedAt` ≤ 26 hours old |
| `dashboard_tunnel` | Tunnel up: the operator machine's loopback port serves the dashboard, verified from that machine itself behind the identity guard (a live tunnel process alone does not pass) |

## The doctor (bounded repair)

Authorized by the operator's direct order (2026-11-25), the doctor may
repair exactly these failures, and nothing else:

- Daemon or keeper **absent** (process count exactly 0): install the
  systemd unit if missing, start the service, verify exactly one process.
- Immune face stale: run the face writer.
- Pulse stale with the daemon alive: hand-fire one pulse.
- Immune fix queue non-empty: for each queued aspect, run that organ's
  own activity pass, then re-run patrol and stations so a recovered
  aspect clears its own station. An aspect with no mapped pass is
  reported NEEDS_HUMAN, never faked fresh.
- Dashboard tunnel absent (process missing): run the guarded launcher,
  which re-probes the far side's identity itself before launching. A
  tunnel that is alive but unverifiable is reported, never killed.

Guards: it acts only on absence, staleness, or a queued aspect; it never
kills or restarts a live process; it never starts a duplicate (counts are
re-read immediately before every start); it stops after 3 attempts per
aspect per rolling hour, after which it reports NEEDS_HUMAN; every
attempt is appended to a ledger. It never touches a state file's
timestamps directly. Queue draining is **not** in the doctor's remit
(confirmed correct behavior 2026-11-25), and neither are the two ACC
consultation checks — those are treated by the drain rounds.

## Supporting fixes landed the same day

- **Keeper results-drop fix (~02:47–02:51).** The keeper merged answer
  drops only into `memory/llm-results/`, but askers read
  `memory/juno-results/` — every results-drop answer was invisible. The
  keeper now writes both directories; the round trip is proven (test ask
  → answer read back by the asker).
- **Gate parse fix.** The thalamus gate's scorer read only the legacy
  signal shape; envelope-shaped signals (everything the conversation wire
  produces) parsed empty and were auto-suppressed. It now reads both
  shapes; the signals suppressed under the broken parse re-scored under
  the fixed parse.
- **Immune face wiring.** The immune face writer is wired into every
  helm pulse, so the face advances with the pulse instead of freezing.

## Known residual notes (not failures)

1. **The dashboard server has no supervisor.** Unlike the daemon and
   keeper, it is not a systemd unit in the live deployment, so a kill
   (as at 05:24 on 2026-11-25) fails the card's tunnel check until the
   server is restarted by hand (`serve-dashboard.sh start`). Whether to
   install a unit for it is the operator's call; an attempt to install
   the documented user unit from the agent's shell could not reach the
   user systemd bus, and installation was not forced.
2. **Glymphatic consultation watermark unused.** The glymphatic organ's
   `lastConsultedAt` is still 2026-11-22: its load-state reader is in no
   round. Its state advances and its face reports; only the consultation
   watermark is stale. Named here so it is a known fact, not a discovery
   waiting to happen.
3. **Gate SLA approximation.** The gate's conversation-flow SLA (900s)
   is met by the wire sweep's 15-minute cadence only approximately.
   No change made.
4. **Self-mod autonomy snapshot staleness.** The autonomy-state
   `computed_at` stamp predates the pass by days; the monitor tick runs
   on schedule. A stale computed snapshot, not a flow blockage.

## Addendum — 2026-11-27 (PST)

Two systems were built and verified live after the snapshot above; both
are in this commit.

**The immune jam.** The heartbeat and the immune system are now tied
together: the patrol aggregates accumulated immune cells per organ, and
any organ at 3 or more cells jams the whole system — the pulse line and
the immune face carry the jam loudly, the daemon defers spawn-type jobs
while it holds, the heartbeat card gained a twelfth check
(`immune_no_jam`, reported on every card check while it holds), and only
an actual repair clears it. Verified end-to-end with a live induced jam
(2026-11-27 ~03:08 PST): fired at exactly 3 cells, showed on every
surface, cleared on repair. Design: the immune-system SKILL.md, "The
jam" section.

**The process stream.** The insula gained a nerve: Juno's process stream
— her work record and her deliberation — is now processed by the harness
and never kept. `skills/insula-memory/scripts/process-stream.py` runs on
every pulse (feeder: keeper results, the doctor's ledger, the daemon
log, completion claims extracted from the transcript) and on Juno's live
tap. It emits only derived features — marker counts, loop score, affect
proxies, claim tallies, SHA-256 digests — and checks completion claims
against the batch's work record; unbacked claims persist as hash-only
candidates for the ACC error organ. Batches carrying deliberation or
claim signal nudge the insula's channels by bounded deltas. Verified
2026-11-27: a sentinel deliberation was processed into features and its
raw text appears in no output file; first feed processed 10,033 work
events and 45 claims (37 backed, 8 candidates). Design: the
insula-memory SKILL.md, "The process stream" section. Regression guards
F13 (jam) and F14 (process stream) hold in the deployment's test suite;
the heartbeat card stands 12/12.

## Addendum 2 — 2026-11-27, later (PST)

**The Field.** `skills/insula-memory/scripts/field-score.py` now runs on
every pulse (hook in `helm-pulse.sh`): it scores six labelled proxy
spokes — noticing the pull, feeling the cost, choosing not to loop,
holding the distinction, revising instead of repeating, staying with
uncertainty — from the process stream's fresh features plus the ACC
state, and writes `field-state.json` for the helm's Field page, which
shows the radar, the basis counts behind each spoke, and the Matrix (a
32³-vertex lattice; each process-stream batch lands once per signal —
process / affect / effort — as a lit cluster with falloff). Verified
live 2026-11-27 (synthetic tests, a live scored run, the page rendering
on the operator's desktop). Regression guard F15.

**The unflappable dashboard tunnel.** The dashboard reverse tunnel
flapped all day on 2026-11-27 (and on the two days before it) for three
root causes, each proven from live code or logs:

1. The tunnel was an unsupervised `setsid nohup` ssh. Every flap of the
   route it rides killed it, and nothing relaunched it until the
   30-minute heartbeat card noticed.
2. The heartbeat doctor's dashboard-server rung verified the server by
   counting processes matching `serve-dashboard.sh` — but the
   launcher's foreground mode execs python, so the healthy process is
   `dashboard-server.py` and the count was always 0. The rung fired
   exactly when the server needed starting and then vetoed the tunnel
   repair it had just enabled (2026-11-27 10:09: "start rc=0,
   is-active=active, processes now 0" while the server was serving).
3. A dead tunnel's sshd child can hold the far end's listen port as a
   root-owned process, invisible to an unprivileged process listing,
   blocking every rebind until killed by PID.

The fix gives every failure mode an owner: the tunnel is now
`aibrain-dashboard-tunnel.service` (unit source in `systemd/`,
Restart=always) running `scripts/dashboard-tunnel-run.sh` — identity
probe first, monitor an existing healthy forward, clear stale
listeners via the operator's passwordless sudo, then exec the ssh in
the foreground. The doctor's server rung verifies by the thing itself
(HTTP 200 on the server's port) and its tunnel repair ensures the
tunnel unit, with the old launcher kept as fallback. Verified
2026-11-27: the fixed rung in a live doctor run (final: ALL PASS), a
stop-the-server drill (rung restored it to 200), the heartbeat card at
12/12, and regression guards F16 (updated) and F17 (new) holding.
Honest limit, stated at the time of writing: the route the tunnel
rides is itself down (a runtime-side outage, recurring and outside the
suite); the unit retries on its RestartSec and self-heals when the
route returns. A tunnel absent during a route outage is weather, not
a suite fault — and the card says which of the two it is.
