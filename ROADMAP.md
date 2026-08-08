# AI Brain Daemon Suite — Roadmap to Full Autonomy

> **Status:** Working roadmap. Companion to [`VISION.md`](VISION.md).
> Maps each stage of the vision onto the code that exists today, names the
> concrete milestones that close each gap, and defines "done" for every
> milestone in terms of the suite's own verification culture (`tests/`
> harnesses + CI must stay green).

## How to read this document

- **Stages** mirror `VISION.md` §3 (Experience synthesis → Eclipsing the
  external harness → Crystallized self-improvement).
- **Milestones (M0–M8) are sequenced**: each row lists what exists, what's
  missing, the concrete change, and the acceptance check. A milestone is
  *done* only when its acceptance check passes and the full local test suite
  (all `tests/run_phase*_harness.sh` plus `tests/run_skill_unit_tests.sh`)
  stays green.
- **Autonomy knobs already exist** and are reused rather than re-invented:
  the executive-load gate (`E >= 0.75` blocks promotion), the graduation
  tracker (`clean_streak_target = 20`, `relaxed_review` vs `full_review`),
  `thresholds.json`, `utility-weights.json`, and `immutable-paths.list`.

---

## Stage 1 — Experience synthesis (current state, hardening)

**Vision:** persistent skills + naturalized experience, supervised by the
suite's own daemon, running under an external harness (Hermes).

| What exists | Where | Notes |
|---|---|---|
| 11+ persistent memory skills | `skills/` | encode/decay/consolidate pipelines, LLM-backed via local `llm-call.sh` |
| Unified scheduler + supervisor | `deep-brain-kernel.py` | PSI, GPU VRAM, cgroups v2, pidfd tracking, per-job timeouts, `--check`/`--status` |
| 29-job schedule, collision-free minutes | `JOBS` table in `deep-brain-kernel.py` | documented in `BRAIN_DAEMON_SCHEDULE.md` |
| Executive function cycle | `core/executive/run-executive-cycle.sh` → `isolated-reflect.sh` → `propose-goals.sh` | scheduled as `executive_goal_cycle` (direct job, minutes 28) |
| Post-deploy self-mod monitoring | `self_mod_monitor` job → `skills/self-mod-runner/scripts/monitor-tick.sh` | scheduled (direct job, minutes 32) |
| Regression + CI | `tests/` + `.github/workflows/ci.yml` (phase harnesses; same cadence as `verification.yml` — push/PR, nightly, weekly deep-verify, on demand) |

**Gap:** the daemon's hardware pillars (PSI trigger, cgroup delegation,
GPU VRAM parsing) are built to spec but not exercised on a real target host.
**Milestone M0 — Host-verified pillars (done when):**
1. `SETUP_COMMANDS.md` executed on a real machine; `--check` passes there.
2. `journalctl --user -u aibrain.service` shows PSI deferral + GPU deferral
   actually firing during a `spawn`-type job, and cgroup delegation confirmed
   via `systemctl --user show -p DelegateControllers aibrain.service`.
3. `--status` shows real success counts with zero unhealthy jobs after 24h.

**Status: `IN PROGRESS` (2026-08-08).** Checkable checklist with recorded
results in `SETUP_COMMANDS.md` §5 (sub-checks 2a–2c there split criterion 2
into its machinery parts). This host so far — criterion 1 ✅ (all 29 jobs
`ok` via `--check`); criterion 2's **machinery** verified/armed: PSI
poll-mode fallback active (`/proc/pressure/*` readable), rootless cgroup
delegation confirmed (`DelegateControllers=cpu cpuset io memory pids`),
and GPU VRAM resolved via the amdgpu sysfs fallback (`vulkaninfo` on this
Vulkan-Tools version emits no `heapBudget`, so the documented fallback
path is the live one). Still pending: a deferral *actually firing* during
a spawn job, and the 24h `--status` clean-run window.

---

## Stage 2 — Eclipsing the external harness

**Vision:** each external-harness function gains an internal replacement
until the Suite *is* the harness. Two external functions are named today:
*supervision* (already internal — the daemon) and *agent reasoning*
(currently delegated to `hermes chat` in every `spawn` job).

### M1 — Scheduled self-mod cycle (the suite proposes its own changes, unsupervised)

- **Exists:** `core/self-mod/run-pipeline.sh` orchestrates
  generate → store → rank → evaluate → deploy → monitor, and
  `generate-proposals-llm.sh` already produces LLM-authored proposals. But
  the pipeline is **on-demand only** — nothing on a schedule triggers it.
- **Change:** add a `self_mod_proposal_cycle` job to the `JOBS` table
  (weekly cadence, new unique minute), invoking
  `run-pipeline.sh --generate-llm` with the suite's own LLM provider — the
  same local `llm-call.sh` provider that M3 formalizes (see M3).
- **Guardrail:** the job defers (never deploys) while the executive-load
  gate or graduation tracker is in `full_review` **and** a human hasn't
  approved. M1 can land with human-approval-only deploys; M2 later enables
  auto-deploy under `relaxed_review` (see M2).
- **Done when:** a new Phase-3-style harness test (`tests/run_phase4_harness.sh`)
  exercises a scheduled cycle end-to-end in an isolated temp suite, and the
  real job appears in `--check` output as `ok`.

### M2 — Autonomy ladder (review frequency becomes a real control)

- **Exists:** `graduation-tracker.sh` already computes
  `review_mode ∈ {full_review, relaxed_review}` from a 20-clean streak and
  `thresholds.json` defines acceptance bands. **But nothing consumes
  `review_mode` to change behavior** — it is informational only.
- **Change:** thread `review_mode` into the pipeline decision: `full_review`
  ⇒ proposals queue for human approval (current behavior); `relaxed_review`
  ⇒ pipeline may auto-deploy under the existing RWLock + divergence +
  monitor gates. Log every autonomy change in provenance
  (`core/provenance/log-provenance.sh`).
- **Done when:** `graduation-tracker.sh review-frequency` output is read by
  `run-pipeline.sh`, a harness test proves `relaxed_review` auto-deploys a
  legal proposal and `full_review` does not, and any failure still resets
  the streak to 0.

### M3 — Inference abstraction (the Suite's own reasoning path)

- **Exists:** every `spawn` job calls `hermes chat -q …` directly
  (`deep-brain-kernel.py::run_spawn`). `skills/*/scripts/llm-call.sh` is the
  local-model utility used by encode pipelines.
- **Change:** introduce a provider abstraction for `spawn` jobs — a
  `spawn-provider.sh` shim that dispatches to `hermes` *or* the local
  `llm-call.sh` endpoint (config: `SPAWN_PROVIDER=hermes|local`), keeping the
  pidfd/lock/timeout machinery intact.
- **Done when:** a `spawn`-type job can run with `SPAWN_PROVIDER=local`
  against the same local server the skills already use, a harness test runs
  a fake spawn via both providers, and `--status` still records outcomes.
- **Status: LANDED.** `core/spawn/spawn-provider.sh` dispatches
  `SPAWN_PROVIDER=hermes|local|agentloop`. The **agentloop** provider runs
  the suite's own **internal agentic loop** (`core/agent-loop/agent-loop.sh`
  + `tools.sh` — multi-turn tool use against the local LLM with an
  allowlisted tool registry and session memory), which is the AUDIT Gap 2
  follow-on: spawn jobs can now reason *and act* without hermes, not just
  route to the local endpoint. Covered by `tests/run_phase6_harness.sh`
  (hermes + local dispatch through the daemon) and
  `tests/run_phase10_harness.sh` (tool-use loop, session memory, unknown-tool
  rejection, `SPAWN_PROVIDER=agentloop` end-to-end).

### M4 — Closed goal-execution loop (goals become actions become lessons)

- **Exists:** `propose-goals.sh` promotes goals into `pfc-state.json` under
  caps (max active, min confidence, load gate). Goals are **static** — no
  code consumes them to act, complete, or learn.
- **Change:** wire active goals into `spawn`-job task text (goal → agent
  turn), add a goal-outcome recorder (success/failure/deadline missed), and
  feed outcomes back through `anterior-cingulate-memory`/`acc-error-memory`
  so flagged-uncertainty→error calibration becomes a real signal source for
  the next proposal cycle (ties M1's proposal generation to M4's outcomes).
- **Done when:** a harness test creates a goal, sees it reflected in a
  spawn task, records an outcome, and the outcome appears in ACC error
  state; PFC state no longer accumulates orphaned `active` goals.

---

## Stage 3 — Crystallized self-improvement

**Vision:** the Suite directs its own expansion; humans are stewards of
direction and safety, not operators.

### M5 — Outcome-driven proposal generation (the suite learns *what* to improve)

- **Exists:** proposals today come from `generate-proposals-llm.sh` prompts;
  monitoring data (`live-metrics.json`) drives auto-rollback only.
- **Change:** enrich proposal generation inputs with the suite's own
  signals — consecutive-failure streaks from `--status`, ACC error lessons,
  VRAM/PSI deferral rates, goal-completion gaps — so the LLM proposes fixes
  for *measured* weaknesses, not generic ones.
- **Done when:** a fixture with a known failing job produces a proposal
  whose target path is that job's script, and a harness test asserts the
  linkage (signal → proposal → target).

### M6 — Self-directed expansion (the suite grows new modules)

- **Exists:** `core/capability-registry.schema.json` +
  `validate-manifest.sh` define what a new capability must declare;
  `check-target.sh` gates mutation to manifest-carrying modules.
- **Change:** allow proposals whose `target_paths` create a *new* module
  (new skill directory + `capability-manifest.json`) under the same
  evaluate/deploy/monitor gates, with the new module's regression harness
  required before deploy.
- **Done when:** the Phase-3 harness's temp-suite flow can propose, evaluate,
  and deploy a brand-new peripheral module (not just patch an existing one),
  and CI stays green.

### M7 — Steward-only operation (the crystallization point)

- **Change:** define an operational autonomy contract:
  **auto-mode** is granted only when, over a rolling window (e.g. 30 days),
  graduation streak stays ≥ target, unhealthy-job count stays 0, and
  auto-rollbacks stay under `thresholds.json` limits. In auto-mode the
  human is consulted only for (a) direction-setting (new goals), (b) new
  immutable-path exemptions, and (c) incident triage. Everything else —
  propose, evaluate, deploy, monitor, rollback, expand — runs on its own
  schedule with full provenance. Every autonomy decision is audited as a
  `log-provenance.sh event` entry (see M8).
- **Done when:** a `status --autonomy` (or equivalent) reports the current
  mode with its evidence, the mode is persisted and logged, and the full
  local suite + CI remain green across every milestone.
- **Status: LANDED.** `deep-brain-kernel.py --autonomy` computes the mode
  from graduation streak + unhealthy-job count + rolling-window auto-rollbacks,
  persists `memory/self-mod/autonomy-state.json`, exits 0 in auto_mode / 1 in
  steward_mode. Covered by `tests/test_autonomy_report.sh` (unit) and
  `tests/run_phase8_harness.sh` (deploy/rollback of new modules under the
  gate).

### M8 — Autonomy mode as a real control (the M7 contract wired into the pipeline)

- **Change:** `run-pipeline.sh --autonomy-gate` reads the persisted autonomy
  mode (`memory/self-mod/autonomy-state.json`) alongside M2's `review_mode`:
  **auto_mode** ⇒ the pipeline may auto-deploy accepted proposals on its own
  schedule under the existing RWLock + divergence + regression + monitor
  gates (human consulted only for direction, immutable exemptions,
  incidents); **steward_mode** ⇒ M2 review gating stands (full_review queues
  for human approval). A missing/unreadable autonomy-state.json is treated as
  steward_mode (fail-safe: never over-grant autonomy on absent evidence).
  The scheduled cycle tick (`proposal-cycle-tick.sh`) refreshes the mode from
  fresh evidence (`deep-brain-kernel.py --autonomy`) before each run, and —
  when steward_mode + full_review would force a defer — **defers the weekly
  cycle entirely** rather than running it (no churn), logs an
  `autonomy.gate.deferred` provenance event, and alerts: a
  `{type:"self-mod", event:"cycle_deferred"}` signal in the shared
  `brain-events.jsonl` plus a `memory/self-mod/last-deferral.json` marker
  that `--status` and the dashboard's `⏸` pill surface.
- **Done when:** a harness test proves auto_mode auto-deploys an accepted
  proposal even in full_review, steward_mode + full_review still queues, and
  the summary records `autonomy_mode`.
- **Status: LANDED.** `tests/run_phase9_harness.sh` covers all four paths
  (auto deploys, steward/full blocks, steward/relaxed deploys, missing-state
  fail-safe) plus no-gate back-compat; `tests/test_cycle_defer_alert.sh`
  covers the deferral + alerting (signal + marker + `--status`);
  `tests/test_autonomy_report.sh` covers the `--autonomy` report itself, and
  `tests/test_provenance_events.sh` covers the `log-provenance.sh events`
  audit CLI (`events --filter autonomy` renders every mode.decided / gate
  outcome).

---

## Sequencing & dependencies

```
M0 (hardening, Stage 1)                    ← do first; everything depends on trust
 │
 ├─ M1 (scheduled self-mod) ──┐
 ├─ M3 (inference abstraction)┤  ← independent; parallelizable
 └─ M4 (goal→action loop) ────┘
        │
        ▼
 M2 (autonomy ladder consumes review_mode; gates M1 auto-deploys)
        │
        ▼
 M5 (outcome-driven proposals) → M6 (new-module expansion) → M7 (steward-only)
        │
        ▼
 M8 (autonomy mode consumed as a control; scheduled cycle self-deploys in auto_mode)
```

**Acceptance for every milestone:** all phase harnesses plus the skill unit
tests pass locally **and** in CI (including any new harness a milestone
introduces, e.g. `run_phase4_harness.sh`), `--check` reports the new job(s)
as `ok`, and no Immutable Core path (`core/self-mod/immutable-paths.list`)
is ever a proposal target.

## What "full autonomy" means operationally

The Suite is at M7 when: it schedules its own improvement cycles; it decides
its own proposal backlog from its own measured weaknesses; it grows new
capabilities under the registry gate; it reverts itself on breach without a
human; and a human's only required roles are direction, safety exemptions,
and incident response — with `provenance` and `--status` recording every
step it took.
