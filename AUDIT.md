# AI Brain Daemon Suite — Vision Gap Audit

> **Status:** Living document. Gap report against [`VISION.md`](VISION.md),
> tracked against the milestones in [`ROADMAP.md`](ROADMAP.md). Every gap
> names the code that proves it, and every milestone check-in updates the
> status column below. This file is the audit trail for "what's missing" —
> not a promise that any gap is still open.

---

## How this audit works

- **Gaps are mapped to ROADMAP milestones.** A gap's status advances from
  `OPEN` → `IN PROGRESS` → `CLOSED` only when its ROADMAP acceptance
  criteria pass (harnesses green in CI, `--check` reports new jobs `ok`).
- **Claims cite code.** Each gap names the exact file/line that evidences it,
  so a fix is verifiable against the same code, not vibes.
- **Scope of this audit:** the three capability areas named at the start —
  scheduled self-mod, internalized inference, closed autonomous goal loop.

---

## Gap 1 — Scheduled self-mod

**Status: `CLOSED` (M1 + M2 landed 2026-08-04)

**What exists today:**

- `core/self-mod/run-pipeline.sh` is the full orchestrator: baseline snapshot →
  ingest proposals → rank → evaluate (sandbox + regression + utility) →
  deploy (RWLock + divergence) → monitor registration. It supports
  `--generate-llm` for LLM-authored proposals.
- One self-mod job is on the schedule: `self_mod_monitor` — a **direct** job
  (hours `2,10,18`, minute `32`) that calls
  `skills/self-mod-runner/scripts/monitor-tick.sh` →
  `core/self-mod/monitor.sh`. That is **post-deploy monitoring only**
  (auto-rollback on metric breach).
- `executive_goal_cycle` (minute `28`) schedules the *goal* cycle — not the
  self-mod pipeline.

**The gap:**

- Nothing on a schedule runs the pipeline itself. The `JOBS` table in
  `deep-brain-kernel.py` states it outright: *"Pipeline runs are on-demand
  (run-pipeline.sh)."* (comment on the `self_mod_monitor` job definition).
- `skills/self-mod-runner/SKILL.md` says the skill "may later invoke
  scheduled pipeline runs" — a forward reference to something that does not
  exist. The daemon will never, on its own, propose → evaluate → deploy a
  capability improvement.
- The autonomy knob is computed but inert: `graduation-tracker.sh` derives
  `review_mode ∈ {full_review, relaxed_review}` from a 20-clean streak, but
  **nothing consumes it** to change behavior. `thresholds.json` and
  `utility-weights.json` are read for scoring, not for autonomy gating.

**Closure criteria (ROADMAP):**

- [x] M1: `self_mod_proposal_cycle` job in the `JOBS` table (weekly cadence,
      unique minute) invoking `run-pipeline.sh --generate-llm`; a
      `tests/run_phase4_harness.sh` exercises a scheduled cycle in an
      isolated temp suite; `--check` reports the job `ok`.
- [x] M2: `review_mode` is read by `run-pipeline.sh`; `full_review` queues
      for human approval, `relaxed_review` may auto-deploy under RWLock +
      divergence + monitor; harness proves both paths; any failure resets
      the streak to 0.

**Last checked:** 2026-08-04. **Next check-in:** when M5 lands.

---

## Gap 2 — Internalized inference

**Status: `CLOSED` (M3 landed 2026-08-04; agentic-loop follow-on remains)

**What exists today:**

- Local inference exists and is used by the encode pipelines:
  `llm-call.sh` (bundled in `anterior-cingulate-memory` and
  `prefrontal-cortex-memory`) hits a local OpenAI-compatible server
  (`http://localhost:1234/v1` by default) with retries — zero cloud
  dependency.
- `core/self-mod/generate-proposals-llm.sh` prefers a **direct local
  OpenAI-compatible call** (`LLM_LOCAL_ONLY=1`, `--provider llamaserver`)
  and only falls back to `hermes chat` with `--provider openrouter` if
  explicitly requested. Verified end-to-end in
  `docs/verification/full_cycle_20260720T234945Z` (a full self-mod cycle ran
  against a local Quality GGUF).
- `semantic-match.sh` uses the local LLM for goal/inhibition matching (with
  heuristic fallback).

**The gap:**

- The **daemon's spawn jobs** — the agent turns for hippocampus encoding,
  amygdala, VTA, basal ganglia, social, ACC error analysis — are hardwired
  to `hermes chat -q … --source daemon` in `deep-brain-kernel.py::run_spawn`
  (the `cmd = ["hermes", "chat", ...]` line). If `hermes` is not in PATH,
  the job is skipped (`run_spawn`'s `shutil.which("hermes")` guard).
- So the Suite's *skills* already reason locally, but the *daemon* still
  depends on the external harness for every spawn-type job. There is no
  `SPAWN_PROVIDER` configuration anywhere.
- The local server is a raw chat-completions endpoint only — there is no
  internal agentic loop (tool use, hooks, session memory) yet to fully
  replace hermes.

**Closure criteria (ROADMAP):**

- [x] M3: a `spawn-provider.sh` shim dispatches `spawn` jobs to `hermes` or
      the local `llm-call.sh` endpoint (`SPAWN_PROVIDER=hermes|local`),
      keeping pidfd/lock/timeout machinery intact; a harness test runs a
      fake spawn via both providers; `--status` still records outcomes.
- [ ] Follow-on (not yet a milestone): internal agentic loop (tool use,
      session memory) to fully replace hermes, not just route to local.

**Last checked:** 2026-08-04. **Next check-in:** when the agentic-loop
follow-on lands.

---

## Gap 3 — Closed autonomous goal loop

**Status: `CLOSED` (M4 landed 2026-08-04)

**What exists today:**

- Goals flow **in**: `core/executive/propose-goals.sh` promotes proposals
  into `pfc-state.json` under caps (max-active `5`, min-confidence `0.65`,
  max-promote `2`, hard gate `E ≥ 0.75` blocks promotion).
- Goals influence **decisions**: `decide.sh` reads active goals, boosts
  matching options (semantic via `semantic-match.sh` or heuristic), and
  writes decisions to `decisionLog` (capped at 30).
- Goals are **counted**: `_count_active_goals()` in `deep-brain-kernel.py`
  feeds the executive-load `G` term.

**The gap — nothing closes the loop:**

- `skills/prefrontal-cortex-memory/scripts/goals.sh` has `add | list |
  complete`, but `complete` is **manual-only** — nothing marks a goal
  complete, failed, or deadline-missed based on outcomes.
- No code consumes `decisionLog` entries to determine whether a goal was
  actually pursued or accomplished.
- ACC error memory (`skills/acc-error-memory/scripts/log-error.sh`,
  `get-lessons.sh`) logs errors/lessons but is **not wired to goal
  lifecycle** — no "goal X failed → lesson → adjust".
- `core/executive/isolated-reflect.sh` even *proposes* "Complete or defer
  lowest-priority active goals to reduce executive load below 0.75" (in its
  `candidate_goals` list) — the system senses stale goals yet has no
  mechanism to act on them. Goals accumulate as `active` forever; since `G`
  counts them, executive load can stay inflated with dead goals.

**Closure criteria (ROADMAP):**

- [x] M4: a goal-outcome recorder (goal → spawn task text; success/failure/
      deadline outcome written back into PFC state); auto-completion and
      deferral of stale goals; decisionLog outcomes feed ACC error
      calibration so flagged-uncertainty→error becomes real signal for the
      next proposal cycle; a harness test proves the full
      goal → action → outcome → learn round trip.

**Last checked:** 2026-08-04. **Next check-in:** when M5 lands.

---

## Cross-cutting findings

1. **The autonomy knobs exist but are not wired.** `graduation-tracker.sh`
   (streak, `review_mode`), `thresholds.json`, and `utility-weights.json`
   are all computed or read, but nothing *changes behavior* off them yet.
   The "self-direction" machinery is architecture-ready but inert.
2. **Two of three gaps are literally "no trigger" and "no return loop."** The
   daemon is an excellent scheduler/supervisor, but it is not yet a
   self-architect: it cannot start its own improvement pipeline (Gap 1) and
   it cannot close a goal's lifecycle (Gap 3).
3. **The foundation is real.** Local-only inference, a working gated self-mod
   pipeline, goal promotion with caps, provenance, and a green CI harness
   suite are all in place. The gaps are wiring and loops, not missing
   groundwork — consistent with ROADMAP's M0 (hardening) → M1–M4 (wiring)
   stage.

---

## Summary table

| Vision requirement | Status | Closest roadmap step |
|---|---|---|
| Suite proposes its own changes on its own schedule | ✅ Weekly `self_mod_proposal_cycle` job; `review_mode` gates deploys | M1 + M2 (landed) |
| Suite reasons without the external harness | ✅ Spawn jobs route via `spawn-provider.sh` (hermes or local `llm-call.sh`) | M3 (landed) |
| Goals close the loop: set → act → learn → reset | ✅ Goal injection → outcome recorder → ACC calibration | M4 (landed) |
| Suite learns what to improve from its own measured weaknesses | ✅ `health-context.sh` feeds failure streaks/lessons/sweep failures into proposal prompts | M5 (landed) |
| Suite grows brand-new modules under the registry gate | ✅ `new_module` proposals (manifest + scripts + tests) evaluate/deploy/rollback | M6 (landed) |
| Steward-only operation: mode computed, persisted, reported | ✅ `deep-brain-kernel.py --autonomy` → `autonomy-state.json`, exit 0/1 | M7 (landed) |
| Autonomy mode is a real control (crystallization point) | ✅ `--autonomy-gate` consumes the mode; auto_mode self-deploys, steward_mode keeps review gating | M8 (landed) |

**Overall:** the Suite is solidly at **Stage 1** of the vision (experience
synthesis under an external harness), with the machinery for Stage 2 present
and now powered. The Stage-2 wiring milestones have all landed:
M1+M2 (the Suite proposes and gates its own changes on a schedule), M3 (the
Suite's own reasoning path is a first-class provider, not a hermes
hardwire), M4 (goals close the loop: set → act → learn → reset), M5
(outcome-driven proposals), M6 (self-directed new-module expansion), M7
(steward-only autonomy mode), and M8 (the autonomy mode is consumed as a
real control — auto_mode self-deploys on schedule). The remaining open items
are the Stage-2 **agentic-loop follow-on** (internal tool use + session
memory to fully replace hermes, not just route to local) and Stage-1
hardening on a real host (M0).

---

*Check-in protocol: after each ROADMAP milestone lands, flip the
corresponding checkbox in `ROADMAP.md` and update the status headers above
in the same pass (so the two docs don't drift apart), re-run the full local
suite + CI, and record the change here with a date.*
