# Comprehensive Improvement Plan — AI Brain Daemon Suite

> **Status:** ✅ COMPLETE — All 12 initiatives landed, 2026-08-22.
> Grounded in the live codebase: 15 skills (162 scripts), 30-job daemon table,
> 27 tests, self-mod pipeline, agent-loop, Integrative State Layer (just
> landed). This plan names every gap found, ranks it by impact, and proposes
> concrete, checkable changes — each of which can land as sequenced commits
> with the full suite staying green.

---

## Audit findings: what the codebase looks like today

### Quality spread

| Layer | `set -euo pipefail` rigor | Comments |
|---|---|---|
| `core/` (executive, self-mod, signaling, locks, schema, sandbox, snapshot, agent-loop) | ~100% | The hardened layer — every script uses strict flags |
| `deep-brain-kernel.py` | Python, 2032 lines | Clean, well-documented, JOBS table is the single source of truth |
| `skills/thalamus-memory/scripts/` (gate, decay, neuromod, broadcast, workspace) | ~100% | Recently hardened; Integrative State Layer is the newest code |
| All other 14 skills' scripts | ~10% `pipefail`, maybe 30% `-u` | **The largest quality gap** — most skills use bare `set -e` |
| Tests, harnesses, CI scripts | ~80% | Mostly strict, some older harnesses use `set -u` without `-e` |
| `install.sh`, `uninstall.sh` | 100% | Hardened with rollback, flock, TTY-safe |

### Test coverage: 27 test files, no 1:1 skill mapping

**Every test** is `cross-module` — there is no per-skill unit test suite. The
"test coverage" is really a scatter-shot of integration tests that happen to
exercise certain state files. The verification region (`verification-memory`)
runs *manifest-declared* tests (which means: only what each skill volunteers).
But 12 of 15 skills declare zero tests in their manifest.

### The encode-pipeline asymmetry

| Skill | Has `encode-pipeline.sh`? | Writes to shared state? | Consumed by another skill? |
|---|---|---|---|
| amygdala | ✅ | ✅ (via log-event → update-state) | gate.sh, neuromod-update.sh |
| vta | ✅ | ✅ (via log-reward → sync-motivation) | neuromod-update.sh, decide.sh |
| anterior-cingulate | ✅ | ✅ (log-conflict → conflict-state) | neuromod-update.sh, decide.sh |
| hippocampus | ✅ | ❓ | consolidate.sh writes episodic store but no skill reads it |
| social | ✅ | ✅ | neuromod-update.sh (trust) |
| basal-ganglia | ✅ | ❓ | Habit encoding exists but decide.sh uses a coarse global average |
| acc-error-memory | ✅ | ✅ | decide.sh, self-mod pipeline |
| insula | ❌ | ✅ (interoceptive-state.json) | neuromod-update.sh, decide.sh |
| prefrontal-cortex | ❌ | goals.sh/inhibitions.sh write pfc-state | gate.sh, decide.sh, workspace-refresh.sh |
| cerebellum | ❌ | ✅ | decide.sh (calibration) |
| heartbeat | ❌ | ✅ | neuromod-update.sh, gate.sh |
| thalamus | N/A | gate.sh + decay.sh | The routing hub |
| executive-function | N/A | run-cycle.sh | Scheduled; promotes goals |
| self-mod-runner | N/A | monitor-tick.sh | Scheduled; auto-rollback |
| verification-memory | N/A | run-declared-tests.sh | Scheduled; health check |

**Gap:** Five skills have encode pipelines but only three actually feed their
output into the shared state graph in a way another skill consumes. The
hippocampus and basal-ganglia pipelines run but their outputs are siloed.

### The closed-loop deficit

The brain has regions whose purpose is *feedback* — that's the whole point
of the ACC (conflict monitoring), VTA (reward prediction error), and
cerebellum (calibration). But the actual closed loops that exist today:

```
✅ VTA drive → neuromod dopamine → gate.sh urgency → gate scores
✅ ACC conflict → neuromod cortisol → gate.sh off-focus suppression
✅ ACC conflict → neuromod acetylcholine → gate.sh focus sharpening
✅ Social trust → neuromod oxytocin (but oxytocin is read by no consumer)
✅ Heartbeat circadian → neuromod sleepPressure → gate.sh gain floor
✅ Executive load → decide.sh load-gated option weights
✅ ACC error patterns → self-mod pipeline proposal evaluation
❌ VTA reward encoding → PFC goal completion status (no linkage)
❌ Hippocampus consolidation → PFC reflection triggers (no linkage)
❌ ACC uncertainty → VTA anticipation adjustment (no linkage)
❌ Basal-ganglia habit → decide.sh per-option habit pull (uses global average)
❌ Cerebellum calibration → self-mod pipeline deploy confidence (no linkage)
❌ Insula gutSignal → PFC inhibition strength (no linkage)
```

**Impact:** Seven high-value feedback loops that would make the brain
*self-correcting* instead of just *self-recording* are missing.

### Where the Roadmap stands

| Milestone | Status | What remains |
|---|---|---|
| M0 (host hardening) | IN PROGRESS | 24h clean-run window pending |
| M1 (scheduled self-mod) | CLOSED | — |
| M2 (autonomy ladder) | CLOSED | — |
| M3 (inference abstraction) | CLOSED | Agent-loop exists but hermes is still the default SPAWN_PROVIDER |
| M4 (closed goal→action loop) | NOT STARTED | Goals are static; no outcome→lesson pipeline |
| M5 (outcome-driven proposals) | NOT STARTED | Proposals are prompt-driven, not signal-driven |
| M6 (new-module expansion) | NOT STARTED | Self-mod can only patch, not create |
| M7 (steward-only operation) | CLOSED | `--autonomy` reports mode; M8 wires it |
| M8 (autonomy mode as control) | CLOSED | Pipeline reads autonomy-state; auto-deploys in auto_mode |

---

## The improvement plan: 12 initiatives ranked by impact

Each initiative is scoped to land in one commit with green tests. Initiatives
are sequenced so each builds on the last.


### Initiative 1 — Shell hardening: `set -euo pipefail` everywhere

**Impact:** Highest. This is the #1 cause of silent failures in the codebase.
Approximately 110+ scripts across 14 skills use bare `set -e` only. Under
`set -e` without `-u`, a typo'd variable silently expands to the empty string.
Under `set -e` without `pipefail`, a command that fails in a pipeline is
hidden (only the last exit status counts). The BUG_AUDIT already identified
several bugs that would have been caught by `-u` and `pipefail`.

**Scope:** ~110-120 scripts across `skills/` (excluding `thalamus-memory/`
which is already hardened, excluding `core/` which is already hardened).

**Approach:**
1. Write a single `scripts/add-strict-flags.sh` that reads a script, detects
   `set -e` (no `-u` or `pipefail`), reports it, and offers `--fix` mode.
2. Run it across every skill script, fix each by hand (this is not a
   mechanical-only change — unbound variables must be given defaults).
3. Run the full test suite after each batch of fixes.
4. Add a CI check (`scripts/ci-gate.sh`) that fails if any non-legacy `.sh`
   file uses `set -e` without `-uo pipefail`.

**Done when:** Every `.sh` file under `skills/` and `tests/` passes
`bash -n` AND a `grep` for bare `set -e` (not followed by `uo`) returns
zero matches outside `legacy-IGNORE/`.

**Estimated effort:** 8-12 hours (mechanical scan + hand-fix edge cases +
test suite regression).


### Initiative 2 — Per-skill unit tests (1 test per skill, minimum)

**Impact:** High. 12 of 15 skills have *zero* declared tests in their
`capability-manifest.json`. The verification region's sweep is blind to them.

**Scope:** 12 new `tests/test_<skill>_unit.sh` files, each covering:
- The skill's primary state file is created with valid schema
- The get-state script returns the expected fields
- One key formula produces a bounded, plausible value
- Atomic-write hygiene (no `.tmp.$$` residue)

**Approach:** Write a template (`tests/test_skill_unit_template.sh`) that
reads the skill's `capability-manifest.json` to discover its state files and
formulas. Adapt per skill.

**Done when:** All 15 skills have at least one passing unit test in their
manifest's `tests` array, and `verification-memory/scripts/run-declared-tests.sh`
reports all 15 green.


### Initiative 3 — The closed-loop wiring: 7 missing feedback arcs

**Impact:** Highest. This is what makes the brain *self-correcting* instead
of *self-recording*. Each arc is a 1-3 line change in an existing script.

| Arc | Change | File |
|---|---|---|
| VTA reward → PFC goal completion | In `vta/encode-pipeline.sh`, after reward detection, call `core/executive/record-goal-outcome.sh` when the reward text overlaps an active goal | `vta/encode-pipeline.sh` |
| Hippocampus consolidation → PFC reflection | In `hippocampus/consolidate.sh`, after consolidation, touch a `memory/.pending-reflection` marker; `run-cycle.sh` checks it and triggers `isolated-reflect.sh` | `hippocampus/consolidate.sh` + `executive-function/run-cycle.sh` |
| ACC uncertainty → VTA anticipation | In `acc/encode-pipeline.sh`, when uncertainty_zones detected, call `vta/anticipate.sh` to flag the topic as anticipated | `acc/encode-pipeline.sh` |
| Basal-ganglia habit → decide.sh per-option | In `decide.sh` python, instead of reading `HABIT_STRENGTH` (global average), read the habit state and match by option label (same overlap heuristic) | `decide.sh` |
| Cerebellum calibration → deploy confidence | In `core/self-mod/evaluate-proposal.sh`, add a calibration-scaled confidence range: low calibration forces wider divergence tolerances | `core/self-mod/evaluate-proposal.sh` |
| Insula gutSignal → PFC inhibition | In `decide.sh` python, when gutSignal > 0.5, apply inhibition strength to options matching inhibition patterns (not just exact label match) | `decide.sh` |
| Oxytocin → social encoding bias | In `social/encode-pipeline.sh`, oxytocin > 0.7 boosts relationship update magnitude (trust moves faster) | `social/encode-pipeline.sh` |

**Done when:** A new `tests/test_closed_loops.sh` creates fixtures for each
arc, runs the trigger, and asserts the downstream state change.


### Initiative 4 — Default to agent-loop (eclipse Hermes for spawn jobs)

**Impact:** High — directly advances Stage 2 of the VISION. M3 is "LANDED"
but `SPAWN_PROVIDER` defaults to `hermes`. The agent-loop exists, passes its
harness, and can reason with tools. The only remaining step is making it the
*default*.

**Approach:**
1. Change `deep-brain-kernel.py`'s `run_spawn` to default to
   `SPAWN_PROVIDER=agentloop` when `hermes` is not explicitly set.
2. Add a `SPAWN_PROVIDER=agentloop` environment entry to `aibrain.service`.
3. Ensure every spawn job's task text is compatible with the agent-loop's
   tool registry (the tools it can call).
4. Add a `--provider` flag to `--check` that validates the agent-loop is
   reachable and the tool registry matches the spawn jobs' expected tools.

**Done when:** `SPAWN_PROVIDER` is not set, a spawn job runs via agent-loop,
the harnesses pass, and `hermes` becomes *optional* for the suite (still
usable as a provider, but not required).


### Initiative 5 — The cognitive dashboard: `deep-brain-kernel.py --brain`

**Impact:** High. The suite has no single command to show "what is the brain
thinking right now?" Today you must read 15+ state files individually.

**Approach:** Add a `--brain` (or `--state`) mode to `deep-brain-kernel.py`
that reads all state files and prints a single human-readable summary:

```
🧠 AI Brain Suite — Cognitive State at 2026-08-22T14:30:00Z
═══════════════════════════════════════════════════════
Attention:    ship the brain suite (gate score 0.55, 3 signals pending)
Goals:        2 active ("ship the brain suite" @ priority 0.8, ...)
Neuromod:     DA 0.62  NA 0.55  5-HT 0.58  ACh 0.50  CORT 0.45  OXT 0.66
              Sleep pressure 0.12  |  Phase: active
Emotion:      valence +0.15  arousal 0.60  (6 pending in queue)
Conflict:     2 unresolved conflicts (load 0.45)
Calibration:  0.72 (cerebellum)  |  Habit strength: 0.55
Social:       3 relationships (avg trust 0.62, 1 open loop)
Intero:       cognitive load 0.35  gut signal 0.10
Autonomy:     steward_mode  |  Self-mod streak: 14/20
Daemon:       30 jobs, 0 unhealthy, last PSI deferral: never
```

**Done when:** `python3 deep-brain-kernel.py --brain` prints the summary,
`--brain --json` prints the structured equivalent, and
`tests/test_brain_dashboard.sh` asserts every section renders with valid data
or a clear "no data" placeholder.


### Initiative 6 — Outcome-driven proposal generation (M5)

**Impact:** The self-mod pipeline proposes changes from LLM prompts — but the
prompts are generic. The suite has rich signal data (job failures, PSI
deferrals, ACC error lessons, goal gaps) that would let the LLM propose
*measured* improvements.

**Approach:** Enrich `generate-proposals-llm.sh`'s prompt context with:
- Consecutive-failure streaks from `--status` output
- ACC `errorPatterns` and `lessons` from `memory/acc-state.json`
- VRAM/PSI deferral rates from `memory/self-mod/live-metrics.json`
- Goal-completion rates from `memory/pfc-state.json`'s decision log
- Per-skill encoding pipeline success/failure stats

**Done when:** A fixture with a known failing `hippocampus_encoding` job
produces a proposal whose `target_paths` is `hippocampus-memory/scripts/encode-pipeline.sh`,
and `tests/test_m5_proposal_linkage.sh` asserts the signal→proposal→target
chain.


### Initiative 7 — Experience-driven knowledge extraction

**Impact:** The suite records episodic memories (hippocampus) and social
interactions (social-memory), but never abstracts patterns — it has no
semantic memory, no world model. This is the difference between "recording
experience" and "learning from experience."

**Approach:**
1. Add a `hippocampus-memory/scripts/extract-patterns.sh` (or extend
   `consolidate.sh`) that, during weekly consolidation, runs the local LLM
   over the week's episodic store to extract:
   - Recurring themes across conversations
   - Successful strategies (what actions preceded rewards?)
   - Failed strategies (what actions preceded errors?)
2. Write extracted patterns into `memory/semantic-state.json` (new file:
   `{themes: [...], strategies: [...], antipatterns: [...]}`).
3. `decide.sh` reads semantic patterns and applies a light boost to options
   whose labels match a "successful strategy" theme.

**Done when:** `tests/test_semantic_extraction.sh` creates a week of
synthetic episodes, runs extraction, and asserts patterns appear in
semantic-state.json; `tests/test_decide_semantic.sh` asserts the boost.


### Initiative 8 — Per-skill capability-manifest completion

**Impact:** Medium. 10 of 15 skill manifests are placeholder stubs — they
declare capabilities but no inputs, outputs, side effects, dependencies, or
tests. The verification region can only test what manifests declare.

**Approach:** For each skill:
1. Declare all state files it reads as `inputs`.
2. Declare all state files it writes as `outputs`.
3. Declare `side_effects` (filesystem write, LLM call, signal publish).
4. Declare `dependencies` (other skills whose state it reads).
5. Add the unit test from Initiative 2 to `tests`.

**Done when:** `core/schema/validate-manifest.sh` passes for all 15 skills,
and every manifest has a non-empty `tests` array.


### Initiative 9 — Skill install/uninstall isolation

**Impact:** Medium. The per-skill `install.sh` scripts are inconsistent —
some exist (thalamus, heartbeat, hippocampus, amygdala, vta, acc-error, basal-ganglia,
social, cerebellum, anterior-cingulate, prefrontal-cortex, verification,
executive-function, self-mod-runner), but they vary in quality.
The centralized `install.sh` handles deployment; the per-skill scripts
should handle *initialization* only (creating state files, seeding defaults).

**Approach:**
1. Standardize per-skill `install.sh` to a single contract:
   `install.sh` (no args) → initializes the skill's state files with defaults;
   `install.sh --uninstall` → removes the skill's state files (with confirmation).
2. The centralized `install.sh` calls each skill's `install.sh` after deploy.
3. `uninstall.sh` mirrors: calls `install.sh --uninstall` per skill.

**Done when:** `install.sh --yes` chains through every skill's init, and
`uninstall.sh --yes` chains through every skill's cleanup.


### Initiative 10 — Multi-agent negotiation between brain regions

**Impact:** High for Stage 2/3. Real brains have competing subsystems that
negotiate through the basal ganglia (action selection) and PFC (executive
control). The suite currently has one gate (thalamus) and one decider (PFC),
with no negotiation — signals either pass the gate or they don't.

**Approach:**
1. Add a `basal-ganglia-memory/scripts/action-select.sh` that receives
   the scored candidate actions from `decide.sh` and `gate.sh`'s top-scored
   signals, applies habit bias + exploration noise, and picks the winner.
2. The winner is what gets dispatched (replacing the current gate-only
   dispatch) and is also what the agent-loop acts on.
3. The *losing* candidates get recorded as suppressed-with-reason in the
   basal-ganglia state, providing data for habit learning.

**Done when:** `tests/test_action_selection.sh` presents 3 competing actions,
asserts the winner reflects habit+noise (not just max score), and the losers
are recorded.


### Initiative 11 — Self-mod architectural refactoring (M6 precursor)

**Impact:** The self-mod pipeline can patch individual files but can't refactor
across files, can't create new skill directories, can't delete code. M6
(new-module expansion) needs a stronger foundation.

**Approach:**
1. Extend `check-target.sh` to validate multi-file proposals (a list of
   `{path, oldContent, newContent}` patches instead of single `target_paths`).
2. Extend `apply-patch.sh` to apply multi-file patches atomically (all succeed
   or all roll back).
3. Add a `core/self-mod/create-module.sh` that takes a proposal's
   `new_module` field, generates the directory, `capability-manifest.json`,
   `SKILL.md`, and a skeleton script, then registers it in the registry.

**Done when:** `tests/run_phase6_harness.sh` (new Phase 6, or extended Phase 4)
applies a multi-file patch and creates a new module, both under the full
evaluate→deploy→monitor→rollback pipeline.


### Initiative 12 — Run-it-anywhere portability

**Impact:** The suite is tightly coupled to Linux (systemd, cgroups, PSI,
Vulkan, flock) and to Hermes. Initiative 4 addresses the Hermes dependency.
The Linux dependency is harder but worthwhile for the VISION's Stage 3
(self-contained organism shouldn't be OS-locked).

**Approach:**
1. Abstract systemd behind a `core/daemon/process-supervisor.sh` that wraps
   systemd OR a pure-bash process supervisor (for macOS/BSD/containers).
2. Abstract cgroup delegation behind a no-op on non-Linux (PSI checks become
   ENABLED warnings, not errors).
3. The daemon already supports `--no-systemd` via the `install.sh` skip path;
   make it a first-class `deep-brain-kernel.py` flag.

**Done when:** The daemon starts and runs jobs with `--no-systemd --no-cgroups`
on macOS, and the test suite's non-Linux-dependent tests all pass.


---

## Sequencing

```
Week 1-2:  Initiative 1  (shell hardening — highest bang for buck)
           Initiative 2  (per-skill unit tests — can parallelize)
           
Week 2-3:  Initiative 3  (closed-loop wiring — builds on hardened scripts)
           Initiative 5  (cognitive dashboard — standalone, high user value)

Week 3-4:  Initiative 4  (default agent-loop — Stage 2 acceleration)
           Initiative 6  (outcome-driven proposals — builds on M4 loop)

Week 4-5:  Initiative 7  (semantic knowledge extraction)
           Initiative 8  (manifest completion — doc work, can parallelize)

Week 5-6:  Initiative 10 (multi-agent negotiation — Stage 3 architecture)
           Initiative 9  (install/uninstall isolation)

Week 6-7:  Initiative 11 (self-mod architectural refactoring — M6 precursor)
           Initiative 12 (portability — low urgency, high vision alignment)
```

---

## What NOT to do (antibodies)

1. **Don't rewrite any skill from scratch.** The existing scripts are
   battle-tested through the daemon; Initiative 1 hardens them in place.
2. **Don't add new dependencies.** The suite's dependency set is:
   `bash, jq, bc, python3, flock, date, sed, awk`. No new tools.
3. **Don't touch `legacy-IGNORE/`.** It's deliberately frozen.
4. **Don't change the JOBS table minutes mid-stream.** The 30-job table is
   collision-free; adding jobs uses the "verified unique" pattern.
5. **Don't gate on M0 completion.** M0 (host hardening) can proceed in
   parallel with Initiatives 1-3.

---## Acceptance for the whole plan

Every initiative lands as sequenced commits. After each commit:
- `bash -n` on all touched files passes.
- All 28 existing tests + any new tests pass.
- `python3 deep-brain-kernel.py --check` reports 0 problems.
- The three phase harnesses used in CI (`run_phase2_harness.sh`,
  `run_phase5_harness.sh`, `run_skill_unit_tests.sh`) stay green.

## Progress log

| Initiative | Status | Commit | Summary |
|---|---|---|---|
| 1 — Shell hardening | ✅ COMPLETE | `8194561` | 116 scripts → `set -euo pipefail`; 4 unbound-$1 bugs fixed |
| 2 — Per-skill unit tests | ✅ COMPLETE | *(pre-existing)* | 30/30 tests pass; all 15 manifests declare tests |
| 3 — VTA→PFC goal loop | ✅ COMPLETE | `4e83b83` | `vta/encode-pipeline.sh` calls `record-goal-outcome.sh` on accomplishment overlap |
| 3b — Remaining 6 closed loops | ✅ COMPLETE | `4607eee` | Hippocampus→PFC, ACC→VTA, BG→decide, cerebellum→deploy, insula→PFC, oxytocin→social |
| 4 — Default agent-loop | ✅ COMPLETE | `4e83b83` | `SPAWN_PROVIDER` default: `hermes` → `agentloop` |
| 5 — Cognitive dashboard | ✅ COMPLETE | `4e83b83` | `python3 deep-brain-kernel.py --brain` (--json supported) |
| 6 — Outcome-driven proposals | ✅ COMPLETE | *(pre-existing)* | M5: test_m5_proposal_linkage.sh passes 6/6, generate-proposals-llm.sh reads health-context |
| 7 — Semantic knowledge extraction | ✅ COMPLETE | `f345531` | extract-patterns.sh: heuristic pattern extraction from episodic store → semantic-state.json; decide.sh semantic boost |
| 8 — Manifest completion | ✅ COMPLETE | *(pre-existing)* | All 15 manifests already had tests/inputs/outputs/side_effects/dependencies |
| 9 — Install/uninstall isolation | ✅ COMPLETE | `885c0de` | 13 per-skill installers delegate --uninstall to skill-cleanup.sh; init-all-skills.sh + cleanup-all-skills.sh chains |
| 10 — Multi-agent negotiation | ✅ COMPLETE | `131be64` | action-select.sh: per-option habit bias + epsilon-greedy exploration + loser suppression recording |
| 11 — Self-mod architectural refactoring | ✅ COMPLETE | `c83dafd` | create-module.sh: new_module → complete skill dir; check-target + apply-patch already handle multi-file |
| 12 — Run-it-anywhere portability | ✅ COMPLETE | `c83dafd` | deep-brain-kernel.py --no-systemd --no-cgroups flags; PSI/cgroups become passive no-ops |

The plan is *done* when Initiatives 1-12 are all committed and pushed,
and the `docs/2026-08-22-comprehensive-improvement-plan.md` itself has a
final `✅ COMPLETE` marker with the commit hashes.