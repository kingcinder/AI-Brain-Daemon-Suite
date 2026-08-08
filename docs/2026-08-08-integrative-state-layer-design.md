# Integrative State Layer (A) — Design Spec

**Date:** 2026-08-08
**Status:** Approved (brainstorm → design review). Ready for implementation planning.
**Roadmap position:** First of three brain-fidelity milestones, in order **A (Integrative
State Layer) → C (sleep/consolidation timing) → B (predictive loop)**. Each milestone is its
own design → plan → implementation cycle; this spec covers A only.

---

## 1. Goal & principles

The Suite is a collection of neurologically-mapped regions wired point-to-point
(`route-signals.sh`, per-skill encode pipelines). Real brains are dominated by **global,
modulatory flows** — chemical state (neuromodulators), the contents of attention, and
top-down expectations — that shape how *every* region processes at once. A closes that gap
by giving the Suite a **composition layer**: two cross-cutting state files that all regions
read, plus the jobs that maintain them.

Principles:

1. **Neutral-by-default.** Every reader treats a missing/absent neuromod vector as neutral
   (all factors = 1.0). Today's behavior is byte-identical until the vector is present and
   meaningful. This is what keeps the entire existing test suite green with zero changes to
   it.
2. **Read-primary, fail-open.** The state files are derived read-outs over the source skill
   states. Missing sources degrade to a partial vector; a fully missing source set yields
   baseline defaults, never a crash.
3. **Follow the hardened patterns.** All new writers use `flock` + `$$`-scoped tmp + atomic
   `mv` (the pattern shipped in the 2026-08-08 bug-audit pass), and distinct lock files per
   state file (no nested same-file locking, no deadlock with gate.sh's backgrounded children).
4. **Small, reviewable, testable.** Exactly two state files, one new daemon job, three read
   hooks. Everything else (dual-process routing, generative self-model, prediction loop) is
   explicitly out of scope and belongs to later milestones.

## 2. Architecture overview

```
vta reward-state ─┐
amygdala emotion  ├─► neuromod-update.sh ──► memory/neuromod-state.json ──┐
acc conflict      │        (job: neuromod_update, ~15 min)                ├─► get-neuromod.sh ──► gate.sh
insula state      ├───────────────────────────────────────────────────────┤                     decide.sh
social trust      │                                                        │                     encode pipelines
heartbeat beat    ┘                                                        │
pfc goals ──────────────► workspace-refresh.sh ──► memory/workspace.json ──┘
gate dispatch (event) ──► broadcast.sh (appends currentFocus/broadcasts)   └──► injected into agent turns
```

- **Periodic:** `neuromod_update` job runs `neuromod-update.sh` (compose + decay + write
  `neuromod-state.json`) then `workspace-refresh.sh` (assemble the `context` block + write
  `workspace.json`).
- **Event-driven:** when a signal passes the gate, `gate.sh` calls `broadcast.sh` to append
  to `workspace.json` (`currentFocus` / `recentBroadcasts`).
- **Readers:** `gate.sh`, `decide.sh`, and the encode pipelines consume the vector through
  `get-neuromod.sh --json` (flock-guarded read, defaults when absent).

## 3. Component 1 — `memory/neuromod-state.json`

### Schema

```json
{
  "version": 1,
  "updatedAt": "2026-08-08T18:00:00Z",
  "modulators": {
    "dopamine":      {"value": 0.62, "source": "vta.reward-state.drive",      "updatedAt": "..."},
    "noradrenaline": {"value": 0.48, "source": "amygdala.arousal+insula",     "updatedAt": "..."},
    "serotonin":     {"value": 0.55, "source": "amygdala.valence",            "updatedAt": "..."},
    "acetylcholine": {"value": 0.51, "source": "gate.attentionFocus+acc",     "updatedAt": "..."},
    "cortisol":      {"value": 0.38, "source": "acc.conflictLoad+insula",     "updatedAt": "..."},
    "oxytocin":      {"value": 0.50, "source": "social.trust",                "updatedAt": "..."},
    "sleepPressure": {"value": 0.21, "source": "circadian.phase+clock",       "updatedAt": "..."}
  },
  "composites": {
    "arousal":    0.49,
    "valence":    0.60,
    "stressIndex": 0.38
  },
  "missingSources": ["insula"]
}
```

### Source mappings and formulas

All values clamp to `[0, 1]`. `clamp(x) = min(1, max(0, x))`. Where a source file or field
is missing, its term contributes 0 (and the source is listed in `missingSources`); where the
entire source set is absent, every modulator defaults to its baseline (0.5, sleepPressure 0).

| Modulator | Baseline | Formula |
|---|---|---|
| dopamine | 0.5 | `clamp(0.5 + 0.6·(drive − 0.5) + 0.15·recent_reward + 0.10·has_anticipation)` — `recent_reward` = 1 if vta `recentRewards` non-empty; `has_anticipation` = 1 if `anticipating` non-empty |
| noradrenaline | 0.5 | `clamp(0.5 + 1.0·(arousal − 0.5) + 0.25·insula_strain + 0.20·recent_activity)` — `insula_strain` from insula state; `recent_activity` = 1 if a heartbeat beat exists within 30 min |
| serotonin | 0.5 | `clamp(0.5 + 0.8·(valence − 0.5))` — amygdala `dimensions.valence` |
| acetylcholine | 0.5 | `clamp(0.5 + 0.10·min(len(attentionFocus), 3) + 0.30·(conflictLoad − 0.5))` — gate `attentionFocus` + acc `conflictLoad` |
| cortisol | 0.5 | `clamp(0.5 + 0.50·(conflictLoad − 0.5) + 0.25·insula_overwhelm + 0.20·recent_error)` — `recent_error` = 1 if an acc-error lesson exists within 24 h |
| oxytocin | 0.5 | `clamp(0.5 + 0.8·(avg_trust − 0.5))` — social-memory mean relationship `trust` |
| sleepPressure | 0.0 | `clamp(hours_since_sleep_phase_end / 24)` — rises through the waking day; reset to 0 at the start of a sleep phase (per heartbeat circadian); fallback: hours since 22:00 UTC |

Composites (computed each update, no persistence): `arousal = 0.6·NA + 0.4·ACh`,
`valence = 0.7·DA + 0.3·5HT`, `stressIndex = cortisol`.

### Decay / allostatic reset

The vector is recomputed from sources on every update, so modulator drift follows source
drift. In addition, any modulator whose source set is entirely stale (> 24 h since the source
file's own `lastUpdated`) is pulled 15 % toward its baseline each update, so the "brain"
settles when its inputs go quiet.

## 4. Component 2 — `memory/workspace.json`

```json
{
  "version": 1,
  "lastBroadcastAt": "2026-08-08T18:02:00Z",
  "currentFocus": {"source": "amygdala-memory", "signal": "positive_state",
                   "action": "pass", "gateScore": 0.55, "at": "..."},
  "recentBroadcasts": [ { ... up to 5 most recent ... } ],
  "attentionFocus": ["ship the brain suite"],
  "context": {
    "phase": "active",
    "goals": ["ship the brain suite"],
    "neuromod": {"drive": 0.62, "arousal": 0.49, "cortisol": 0.38, "sleepPressure": 0.21},
    "lastUpdated": "2026-08-08T18:00:00Z"
  }
}
```

- `currentFocus` / `recentBroadcasts` are written **event-driven** by `broadcast.sh`,
  called from `gate.sh` dispatch for every non-suppressed signal.
- `attentionFocus` mirrors `gate.sh`'s boosted-goal list.
- `context` is assembled **periodically** by `workspace-refresh.sh`: circadian phase (from
  `beat.sh` logic), active PFC goals, and a neuromod snapshot. This block is what gets
  injected into agent turns (the "contents of attention" made first-class).

## 5. Mechanics

### New daemon job

`neuromod_update` — direct job, every 15 min, on a collision-free minute per the JOBS table
(concrete minute resolved against `BRAIN_DAEMON_SCHEDULE.md` during planning). It runs:

1. `skills/thalamus-memory/scripts/neuromod-update.sh` → writes `memory/neuromod-state.json`
2. `skills/thalamus-memory/scripts/workspace-refresh.sh` → writes `memory/workspace.json`

Both writers take the hardened locking pattern (`exec 200>...lock; flock 200`; `$$`-scoped
tmp; atomic `mv`). Lock files: `neuromod-state.json.lock` and `workspace.json.lock` —
distinct files; `broadcast.sh` takes `workspace.json.lock` only. `gate.sh` holds
`thalamus-state.json.lock` while calling `broadcast.sh` (a different lock file — no nesting,
no deadlock with its backgrounded target children, which never touch the workspace lock).

### Reader helper

`skills/thalamus-memory/scripts/get-neuromod.sh [--json | --get <modulator>]` — flock-guarded
read of `neuromod-state.json`; prints `{"value":<v>,"composites":{...}}` or `0.5` when the
file/field is absent (the neutral default). All three reader sites source this helper, so
modulation stays in one place.

## 6. Read hooks

### 6.1 `gate.sh` — chemical gain on the five dimensions

Applied multiplicatively around neutral 1.0 (absent vector ⇒ factors 1.0 ⇒ identical scores):

| Modulator | Effect on gate scoring |
|---|---|
| noradrenaline | `urgency_factor = 0.7 + 0.6·NA` → `urgency = base_urgency · urgency_factor` (range 0.7–1.3) |
| dopamine | goal-relevance weight `0.35 → 0.35·(0.8 + 0.4·DA)` (range 0.28–0.42) — motivational salience |
| acetylcholine | focus sharpening: when `ACh > 0.6`, non-`attentionFocus` signals get `score ×= (1 − 0.3·(ACh−0.6)/0.4)` — distractors dampened |
| cortisol | off-focus suppression: `score ×= (1 − 0.25·cortisol)` for signals outside `attentionFocus` |
| sleepPressure | circadian gain floor: `gain' = gain·(1 − 0.3·sleepPressure)` |

The existing action thresholds (amplify ≥ 0.70, pass ≥ 0.40, attenuate ≥ 0.20) are unchanged;
modulation only moves scores across them. On every non-suppressed dispatch, `gate.sh` calls
`broadcast.sh` with the scored signal.

### 6.2 `decide.sh` — arbitration reads the layer

`decide.sh` reads `get-neuromod.sh` and `workspace.json` before arbitration:

- Goal-aligned options: `weight ×= (0.8 + 0.4·DA)` when the option description overlaps an
  active goal (same overlap heuristic the gate uses).
- Somatic bias: when `cortisol > 0.6`, options whose description contains high-uncertainty
  markers get `weight ×= (1 − 0.2·cortisol)` — under stress, prefer the known over the novel.
- The `context` block (phase + goals + neuromod snapshot) is included in the arbitration
  context so downstream choices are informed by the brain's global state.

### 6.3 Encode pipelines — threshold modulation (2–3 pipelines for A)

| Pipeline | Rule |
|---|---|
| anterior-cingulate `encode-pipeline.sh` | stress sensitivity: when `stressIndex > 0.6`, minimum exchange count to trigger analysis drops from 2 to 1 (under stress, conflicts are flagged on thinner evidence) |
| vta `encode-pipeline.sh` | reward-starved sensitivity: when `dopamine < 0.4`, estimated reward intensity `×= 1.15` (small wins feel bigger when reward-starved) |
| amygdala `encode-pipeline.sh` | arousal amplification: estimated emotion intensity `×= (1 + 0.3·(NA − 0.5))` |

All three read through `get-neuromod.sh`; absent vector ⇒ factor 1.0 ⇒ today's behavior.

## 7. Error handling & compatibility

- Missing `neuromod-state.json` / `workspace.json` at read time ⇒ neutral defaults, no
  crash, no stderr noise in the happy path.
- Missing source files at update time ⇒ partial vector + `missingSources` list; all-missing
  ⇒ baselines. The update job exits 0 and logs which sources were missing.
- Update job failure ⇒ no state write (atomic), previous vector stands, next tick retries.
- **Compatibility guarantee:** with no neuromod file present (fresh install, all existing
  tests, existing live workspaces), every modulated quantity equals today's value. This is
  enforced by `tests/test_gate_neuromod.sh` (below).

## 8. Testing

| Test | What it asserts |
|---|---|
| `tests/test_neuromod_state.sh` | Each source→modulator mapping; clamping at 0/1; decay pull-to-baseline; missing-source partial vector; all-sources-missing ⇒ baselines; atomic write + lock file present |
| `tests/test_workspace_broadcast.sh` | publish → gate → `workspace.json` carries `currentFocus`; `recentBroadcasts` ring behavior; `workspace-refresh.sh` assembles `context` (phase, goals, neuromod snapshot) |
| `tests/test_gate_neuromod.sh` | (a) Given a neuromod fixture, gate scores shift as specified (e.g. high NA raises urgency, high DA raises goal-relevance); (b) **absent neuromod ⇒ scores identical to a run without the layer** (the regression lock) |

Existing `tests/test_thalamus_gate.sh` and the full 24-test suite + phase harnesses +
skill-unit suite must stay green **without modification**. Capability manifests for touched
modules declare the new tests (thalamus-memory declares all three; acc/vta/amygdala declare
no new tests for A, their encode changes are covered by the existing pipeline paths).

## 9. File change list

**New**
- `skills/thalamus-memory/scripts/neuromod-update.sh`
- `skills/thalamus-memory/scripts/get-neuromod.sh`
- `skills/thalamus-memory/scripts/workspace-refresh.sh`
- `skills/thalamus-memory/scripts/broadcast.sh`
- `tests/test_neuromod_state.sh`
- `tests/test_workspace_broadcast.sh`
- `tests/test_gate_neuromod.sh`
- `docs/2026-08-08-integrative-state-layer-design.md` (this spec)

**Modified**
- `deep-brain-kernel.py` — JOBS table: add `neuromod_update` direct job (collision-free minute)
- `skills/thalamus-memory/scripts/gate.sh` — read neuromod vector; apply gain factors;
  call `broadcast.sh` on non-suppressed dispatch
- `skills/prefrontal-cortex-memory/scripts/decide.sh` — read neuromod + workspace context;
  DA goal-alignment multiplier; cortisol uncertainty bias
- `skills/anterior-cingulate-memory/scripts/encode-pipeline.sh` — cortisol exchange threshold
- `skills/vta-memory/scripts/encode-pipeline.sh` — dopamine intensity factor
- `skills/amygdala-memory/scripts/encode-pipeline.sh` — NA intensity factor
- `skills/thalamus-memory/capability-manifest.json` — declare the three new tests
- `BRAIN_DAEMON_SCHEDULE.md` — document the `neuromod_update` job

## 10. Scope boundaries (explicitly NOT in A)

- Dual-process (System 1/System 2) habit-vs-deliberation routing in `decide.sh`.
- Generative self-model narrative (integrated SELF.md / stream of consciousness).
- Prediction/surprise gating (expectations published by goals/anticipations; gate surprise
  dimension) — milestone B.
- Sleep architecture (NREM/REM consolidation jobs, state-gated scheduling) — milestone C
  (sleepPressure in A is the seam C will consume).
- No changes to `route-signals.sh` routing semantics, the executive cycle, or the
  self-modification pipeline.

## 11. Sequencing within A

| Step | Delivers | Green-check |
|---|---|---|
| A1 | `neuromod-update.sh` + `get-neuromod.sh` + state schema + `neuromod_update` job + `test_neuromod_state.sh` | Full suite green; `--check` shows the job `ok` |
| A2 | `workspace-refresh.sh` + `broadcast.sh` + `workspace.json` + `test_workspace_broadcast.sh` | Full suite green |
| A3 | Read hooks (gate / decide / 3 encodes) + `test_gate_neuromod.sh` + manifests + `BRAIN_DAEMON_SCHEDULE.md` | Full suite green; absent-vector regression lock passes |

Every step lands with the whole suite green — nothing is ever half-wired.

## 12. Acceptance criteria

1. `bash tests/test_neuromod_state.sh` — all mapping/clamp/decay/fallback cases pass.
2. `bash tests/test_workspace_broadcast.sh` — broadcast + context assembly pass.
3. `bash tests/test_gate_neuromod.sh` — modulation shifts scores as specified AND the
   absent-vector regression lock passes.
4. Full local suite stays green with **zero modifications** to existing tests:
   `tests/test_*.sh` (24), phase harnesses, `run_skill_unit_tests.sh`, `bash -n` all files.
5. `deep-brain-kernel.py --check` reports `neuromod_update` as `ok` (29 → 30 jobs).
6. Live run (workspace install) produces `memory/neuromod-state.json` and
   `memory/workspace.json` with sane, bounded values and non-empty `missingSources` handling.
7. All writes are flock-guarded + atomic per the audit pattern; no new deadlock chains
   (verified by review of caller graphs: broadcast from gate, refresh/update from the job,
   no nested same-file locking).
