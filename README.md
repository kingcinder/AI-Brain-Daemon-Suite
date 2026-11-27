# AI Brain Daemon Suite

> **Mission & scope:** see [`VISION.md`](VISION.md) — the official statement
> of what this suite is, what it is for, and where it is headed.
> **Verified live state:** see [`CURRENT_STATE.md`](CURRENT_STATE.md) — the
> dated 2026-11-25 verification of the running deployment, with a
> 2026-11-27 addendum.

## What this is

The AI Brain Daemon Suite is a persistent cognitive harness for a single
agent (Juno): a set of 19 neurologically-mapped organ skills that encode,
decay, consolidate, and reflect on experience; a scheduler daemon that runs
their passes on a fixed table; a keeper that moves questions and answers
between the organs and the agent; a signal gate that routes everything the
agent and the organs say to each other; and a self-modification pipeline
that lets the suite propose, evaluate, deploy, and roll back changes to
itself under an approval gate.

The suite is the live harness of the agent who runs it. Since the Stage 3
cutover on 2026-11-10, exactly one instance runs on real state, in the
agent's own workspace, under systemd units whose sources ship in
`systemd/`. The external harness the suite originally ran under (Hermes
Agent) is no longer in the loop of the live deployment; the integration
code and audit trail for it are retained in the tree (see
[`HERMES_COMPATIBILITY.md`](HERMES_COMPATIBILITY.md)).

## Documentation index

| Doc | What it answers |
|---|---|
| [`VISION.md`](VISION.md) | What is this suite, what is it for, and where is it headed? (**read first**) |
| [`CURRENT_STATE.md`](CURRENT_STATE.md) | What is the verified state of the live deployment, as of 2026-11-25? |
| [`ROADMAP.md`](ROADMAP.md) | Which milestones get us to full autonomy, and which have landed (M0–M8)? |
| [`AUDIT.md`](AUDIT.md) | Which vision gaps are open or closed, and what code proves it? |
| [`BRAIN_DAEMON_SCHEDULE.md`](BRAIN_DAEMON_SCHEDULE.md) | What jobs does the live daemon run, on what schedule, and why? |
| [`NEUROSCIENCE_MAPPING.md`](NEUROSCIENCE_MAPPING.md) | Which brain-region skill names are functionally grounded, which are structural or label-only, and why? (honesty audit) |
| [`HERMES_COMPATIBILITY.md`](HERMES_COMPATIBILITY.md) | How did the suite interoperate with the Hermes Agent harness? (audit of the Sept tree; superseded for the live deployment — see its 2026-11-25 status note) |
| [`HERMES_DEPS_CHECKLIST.md`](HERMES_DEPS_CHECKLIST.md) | Which external-harness functions have been internalized, and which still require the binary? |
| [`BUGFIX_HISTORY.md`](BUGFIX_HISTORY.md) | The suite-wide bug-hunting and repair audit trail. |
| [`REFACTOR_SURVEY.md`](REFACTOR_SURVEY.md) | The substrate-binding survey that preceded the runtime-contract work. |
| [`SETUP_COMMANDS.md`](SETUP_COMMANDS.md) | Host-level setup and verification steps for the daemon engines. |
| [`AGENTS.md`](AGENTS.md) | Project rules: immutable core, layout, and standing verification discipline. |

## The 19 organs

Each organ is a skill package under `skills/` with persistent state,
encode/decay (or equivalent) passes, and a dashboard fragment. One-line
roles:

| Skill | Role |
|---|---|
| `hippocampus-memory` | Episodic memory — scores and encodes experience, decays traces, consolidates them into long-term themes. |
| `amygdala-memory` | Emotional state — valence/arousal dimensions plus a named-emotions layer; salience tagging of high-arousal events. |
| `vta-memory` | Reward and drive — reward logging with TD reward-prediction error; drive decay; the reward intake Juno judges each drain round. |
| `basal-ganglia-memory` | Habits and action selection — arbitration among competing candidate actions, with a no-go threshold. |
| `insula-memory` | Interoception — internal channels (gut signal, cognitive load, friction, self-coherence, …) with per-channel prediction error. |
| `anterior-cingulate-memory` | ACC, conflict half — predictive conflict/uncertainty flags raised *while* reasoning, tracked as a conflict load. |
| `acc-error-memory` | ACC, error half — confirmed error patterns recorded *after* a mistake, with severity escalation and regression detection. |
| `prefrontal-cortex-memory` | Arbitration and filtering — goal-biased decision-making (`decide.sh`); also the prefrontal filter that tags incoming signals clean / held / quarantined before they reach the hippocampus (originals are never edited). |
| `social-memory` | Relationships — trust and affinity updated by social prediction error; decay of stale ties. |
| `cerebellum-memory` | Calibration — per-skill precision and smoothness, forward-model prediction error, periodic refine passes. |
| `heartbeat-memory` | The pulse and the heart — circadian beat, the helm pulse that refreshes every organ's public face, and the dashboard assembly trigger. |
| `hypothalamus-memory` | Homeostatic regulation — an hourly `regulate` pass over the suite's internal-state set-points. |
| `claustrum-memory` | Binding — an hourly `bind` pass integrating signals across organs. |
| `glymphatic-memory` | Clearance — a sweep that finds orphaned data stores, stale flows, and overstaying pending files, and reports them. |
| `thalamus-memory` | The gate — scores and routes every signal on the bus (`gate.sh`), maintains the global neuromodulator vector, decays suppressed signals past their retry window. |
| `executive-function` | Goal cycle — isolated reflection, goal proposal and promotion under load gates, goal-outcome recording. |
| `verification-memory` | Proprioception — the manifest-driven sweep that runs every test each module declares; also the self-mod pipeline's pre-deploy regression gate. |
| `immune-system-memory` | Self-repair surveillance — patrol compares each organ's face against its station thresholds; breaches enqueue fix-queue items that are repaired by running the affected organ's own activity pass. (Built 2026-11-24; the 19th organ.) |
| `self-mod-runner` | The self-modification pipeline's runner skill — schedules the proposal cycle and the post-deploy monitor ticks for `core/self-mod/`. |

### Why are there two ACC skills?

`anterior-cingulate-memory` and `acc-error-memory` both map to the anterior
cingulate cortex and can look redundant at a glance — they're not the same
skill split in two, they cover two different timings of the same brain
region's job:

| | `anterior-cingulate-memory` | `acc-error-memory` |
|---|---|---|
| **Fires on** | The agent noticing conflicting information, ambiguous intent, or rising uncertainty *while reasoning, before acting* | A correction actually made, *after* the agent said or did something wrong |
| **Nature of signal** | Predictive / a "something feels off" flag | Confirmed / a recorded mistake |
| **Live driver** | Daemon `acc_conflict_encoding` job (every 3h) + the helm-drain conflict round | The helm-drain error round (screens candidate error exchanges with Juno, logs confirmed patterns) |

**Routing rule when it's not obvious which one applies:** if the signal
exists before the agent commits to an action or answer, it's
`anterior-cingulate-memory`'s. If it exists only because something was
already wrong, it's `acc-error-memory`'s. It's normal — not duplicate
logging — for the same underlying issue to show up in both: a conflict flag
during the session, and an error record later if the uncertain guess turned
out wrong. That pairing is itself useful signal (calibration: how often
flagged uncertainty predicts an actual error), which is part of why both
are kept separate rather than merged.

## Architecture

**Daemon (`brain-daemon.sh`).** The live scheduler. A single JOBS table of
25 `direct` jobs (see [`BRAIN_DAEMON_SCHEDULE.md`](BRAIN_DAEMON_SCHEDULE.md)),
every job on a minute no other job uses, with PSI-based backpressure.
`brain-daemon.sh --check` validates the table (script paths, minute
uniqueness) without starting anything. The tree also carries
`deep-brain-kernel.py`, the Python engine from the September line of work;
in the current deployment the bash daemon is the one running (see
[`CURRENT_STATE.md`](CURRENT_STATE.md)).

**Keeper (`bin/helm-keeper`).** The bus tender. Organs and pipelines ask
Juno questions by enqueueing *juno-ask* entries; answers are dropped as
files into a results-drop directory, and the keeper merges each drop into
both `memory/llm-results/` and `memory/juno-results/` (askers read the
latter — writing both is a 2026-11-25 fix; see
[`BUGFIX_HISTORY.md`](BUGFIX_HISTORY.md)). The keeper also maintains the
helm health record (queue depth, deadletter count).

**Gate and conversation wire (`core/gate/`).** Every turn of the agent's
main conversation is ingressed as a gated envelope (`core/gate/envelope.py`)
onto the signal bus (`memory/brain-signals.jsonl`); the thalamus gate
scores and routes bus signals to the organs, checkpointed so nothing is
processed twice. The flow registry (`core/gate/flows.json`, 73 flows) names
every producer/consumer pair, which is what the glymphatic sweep audits for
orphans. A transcript bridge rewrites the wire payloads into the transcript
shapes the ACC encoders read. A 15-minute sweep backstops the wire so no
turn depends on the agent remembering to ingress it.

**Helm drain.** Juno is the only drainer of the ask queue. A drain round
(every 15 minutes) answers pending asks in the exact shape each requests,
then drives the ACC rounds (conflict encoding, error screening, resolution
checks, and both organs' state consultations) and the VTA reward round
(judging pending reward candidates — only genuine reward moments from the
conversation are encoded; worker boilerplate is rejected).

**Self-modification (`core/self-mod/` + `self-mod-runner`).** The pipeline
proposes, ranks, evaluates (sandbox + the verification region's declared-
test sweep), deploys, monitors, and rolls back changes to peripheral
modules; immutable core paths are never targets. The approval gate is
Juno's: since 2026-11-13 the pipeline defers to her judgment on the
verification evidence, not to a human approver. Ledger at the 2026-11-25
verification: 17 proposals — 9 deployed, 5 rejected, 2 rolled back,
1 ranked; autonomy state `steward_mode`, auto-deploy off.

**Dashboard.** Each organ writes a fragment (`memory/dashboard-fragments/`);
the shared builder assembles them into `brain-dashboard.html`. The page is
served live by `scripts/dashboard-server.py` on a loopback port (8123)
via `scripts/serve-dashboard.sh`, with a token-gated `POST /__regenerate`
endpoint and auto-reload on file change; a static copy is also delivered
to the operator's desktop, and the live page is exposed back to the
operator's machine through a loopback-only reverse tunnel, so the operator
watches the same build the agent sees.

**Immune system (`immune-system-memory`).** A patrol (wired into the helm
pulse) compares each organ's reported face against its station thresholds.
A breached aspect enters the fix queue; repair means running that organ's
own activity pass (regulate, bind, beat, decay, clearance-sweep, …) and
letting the next patrol clear the station — aspects are never faked fresh.

**Heartbeat card and doctor.** An operator-side card (`HEARTBEAT.md`)
states 11 health checks for the live harness — pulse freshness, 19/19
organs, queue drained, keeper health, exactly one daemon and one keeper,
immune face freshness, immune queue clear, both ACC consultation
watermarks, and the dashboard tunnel. A checker runs the card every 30
minutes. On failure, a bounded *doctor* may repair only absence,
staleness, or a queued aspect: it never kills or restarts a live process,
never starts a duplicate, stops after 3 attempts per aspect per hour, and
ledgers every attempt. A regression suite (sections F1–F11) guards the
card, checker, and doctor against the exact failures they have already
had once.

## How it runs

```bash
# supervision (unit sources in systemd/)
systemctl status aibrain.service        # the daemon (brain-daemon.sh)
systemctl status helm-keeper.service    # the keeper (bin/helm-keeper)

# validation and health
bash brain-daemon.sh --check            # job table: paths + minute uniqueness
# heartbeat card check + regression suite: operator-side tooling,
# run against the live deployment (see CURRENT_STATE.md)

# dashboard (live serve)
bash scripts/serve-dashboard.sh start   # loopback :8123, auto-reload
bash scripts/serve-dashboard.sh status
```

Deployment notes: exactly one daemon and one keeper may run against a
workspace — the checker counts *top-level* processes only, because both
programs spawn children that a naive count would mistake for duplicates.
The daemon's log is the first place to look when a pass misbehaves; job
failures surface in the daemon's check/status output and in the helm
health record, not silently.

## Repo layout

| Path | Purpose |
|---|---|
| `skills/` | The 19 organ skill packages (see the roster above). |
| `core/` | The foundation: gate (envelope, flows, wire), self-mod pipeline, executive cycle, agent loop, locks, concurrency, provenance, sandbox, snapshot, schema, dashboard builder, spawn providers, transcripts. |
| `brain-daemon.sh` | The live scheduler: 25-job table, PSI backpressure, `--check` mode. |
| `deep-brain-kernel.py` | The Python engine from the September line (async scheduler + pressure supervisor). In the tree; not the engine running in the current deployment. |
| `bin/` | Helm tooling: the keeper, telemetry snapshot/delivery, invariant patrol, organ digest. |
| `scripts/` | `serve-dashboard.sh` + `dashboard-server.py` (live dashboard), `ci-gate.sh`, `deep-verify.sh`. |
| `systemd/` | Unit sources: `aibrain.service`, `helm-keeper.service`, `aibrain-dashboard.service` (plus shadow variants used for cutover testing). |
| `tests/` | Phase harnesses and per-skill unit suites, including the verification region's self-test. |
| `docs/` | Design specs, runbooks, and verification evidence from the suite's build-out (historical records). |

## State as of 2026-11-25

A full verification pass was run against the live deployment on
2026-11-25 (criteria written before the pass; every claim measured live).
Headline: heartbeat card **11/11 PASS**; heartbeat regression suite
**58/58, all guards hold**; 19/19 organs present and reporting. The full
report is summarized in [`CURRENT_STATE.md`](CURRENT_STATE.md).

What changed since the September 10 tree this repo previously described:

- **Stage 3 cutover (2026-11-10).** The suite's live instance moved into
  the agent's own workspace; the bash daemon + keeper under the `systemd/`
  units are the running supervision. Exactly one instance runs on real
  state, ever.
- **Approval gate transferred (2026-11-13).** Self-mod approval authority
  sits with Juno, exercised on verification evidence; the gate did not
  disappear, its holder changed.
- **Four new organs.** Hypothalamus (regulation), claustrum (binding),
  glymphatic (clearance), and the immune system (2026-11-24) took the
  roster from 15 to 19. The heart is counted inside the 19 (ruling of
  2026-11-24).
- **ACC organs installed end-to-end (2026-11-25).** Both ACC organs'
  processing halves had no driver from 2026-11-22; the drain rounds now
  drive them, their state consultations are watermarked, and — after the
  D1 fix — both write dashboard fragments in the shared idiom, so Errors
  and Conflicts actually appear on the dashboard.
- **Results-drop fix (2026-11-25).** The keeper wrote answers only where
  nobody read them; it now writes both result directories, and the round
  trip is proven.
- **Conversation wire (2026-11-25).** Every conversation turn enters the
  harness as a gated envelope; the ACC encoders read the conversation
  through the transcript bridge the wire feeds.
- **Dashboard live-serve + tunnel (2026-11-25).** The dashboard is served
  live on loopback with a working regenerate endpoint, delivered to the
  operator's desktop, and tunneled back to the operator's machine —
  verified from that machine, behind an identity check.
- **Verification findings D1–D6 (2026-11-25).** ACC reporting, the frozen
  VTA reward intake (133 stale entries, all boilerplate, judged and
  cleared), four unscheduled organ passes (five jobs added to the daemon
  table), glymphatic registry drift, the far-side copy's undrained queue
  (567 entries archived with hash verification and cleared the same day),
  and the never-incremented ACC screening counters. Details in
  [`CURRENT_STATE.md`](CURRENT_STATE.md).
- **Heartbeat card + doctor + regression suite.** The card's 11 checks,
  the bounded repair doctor, and the F1–F11 regression suite (58/58) are
  the standing health gate for the live deployment, replacing
  point-in-time manual checks.

Known residuals (named, not hidden): the dashboard server has no systemd
supervisor in the live deployment — if it dies, the card's tunnel check
fails and the server is restarted by hand; and the glymphatic organ's
consultation watermark is unused (its state advances and its face reports;
only the watermark is stale). Both are recorded in
[`CURRENT_STATE.md`](CURRENT_STATE.md). (The dashboard-supervision
residual was closed on 2026-11-27 — see the next section.)

## State as of 2026-11-27

Two systems were built and verified live after the 2026-11-25 pass; both
are in the tree. The heartbeat card stands **12/12 PASS**. Details in the
2026-11-27 addendum to [`CURRENT_STATE.md`](CURRENT_STATE.md).

- **The immune jam (2026-11-27).** The heartbeat and the immune system
  are now tied together: the patrol aggregates accumulated immune cells
  per organ, and any organ at 3 or more cells jams the whole system —
  the pulse line and the immune face carry the jam loudly, the daemon
  defers spawn-type jobs while it holds, the heartbeat card gained a
  twelfth check (`immune_no_jam`, reported on every card check while it
  holds), and only an actual repair clears it. Verified end-to-end with
  a live induced jam (fired at exactly 3 cells; cleared on repair).
  Design: the immune-system `SKILL.md`, "The jam" section. Regression
  guards F13.
- **The process stream (2026-11-27).** The insula gained a nerve: the
  agent's process stream — her work record and her deliberation — is
  processed by the harness and never kept.
  `skills/insula-memory/scripts/process-stream.py` runs on every pulse
  and on the agent's live tap, emits only derived features (marker
  counts, loop score, affect proxies, claim tallies, SHA-256 digests),
  and checks completion claims against the batch's work record;
  unbacked claims persist as hash-only candidates for the ACC error
  organ. Verified with a sentinel deliberation: processed into
  features, its raw text present in no output file. Design: the
  insula-memory `SKILL.md`, "The process stream" section. Regression
  guards F14.
- **Dashboard supervision (2026-11-27).** The dashboard server now runs
  under `aibrain-dashboard.service` (Restart=always; kill-tested live),
  and the unit source ships in `systemd/` — its only copy previously
  sat in /etc, and a VM replacement ate it.
