# AI Brain Suite V4.0 — Implementation process by phase

**Canonical tree:** `/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE`  
**Plan source:** V4.0 dependency-ordered phases (not calendar weeks).  
**Related:** [V4_STATUS.md](./V4_STATUS.md) (checklist), project `AGENTS.md` (local rules).

---

## Guiding process (all phases)

1. **Respect Immutable Core** — never self-modify `decide.sh`, locks/RWLock, semaphore, sandbox, executive-load calculator, or (once present) the self-mod pipeline as a *proposal target*.
2. **Build peripherals with manifests** — only modules with valid Capability Registry manifests (`immutable: false`) are legal change targets later.
3. **Prove with harnesses** — each phase lands scripts + automated tests before claiming done.
4. **Wire into the daemon only when safe** — prefer *direct* (non-inference) jobs; gate inference with load/semaphore rules.
5. **Document status** — `docs/V4_STATUS.md` + project `AGENTS.md` track path and verify commands.

---

## Phase 1a — Foundation

### Goal

Make the suite **crash-safe, version-aware, and auditable** without changing arbitration (`decide.sh`).

### Implementation process

| Step | What was done |
|------|----------------|
| 1. PID / crash recovery | `core/locks/pid-lock.sh` — acquire, heartbeat, release, stale reclaim |
| 2. Schema skeleton | `core/schema/schema-registry.json` + `validate-schema.sh` |
| 3. Provenance | `core/provenance/log-provenance.sh` — proposal id, SHA-256, scores, rollback status → JSONL |
| 4. Regression entry | Existing `tests/pfc_decide_harness.sh` kept; new `tests/run_phase1_harness.sh` wraps core helpers + decide closed-loop |
| 5. Constraint check | `decide.sh` **not** edited — only exercised |

### Outcome

- Foundation primitives exist under `core/`
- Phase 1 harness green (**27** assertions when re-run later with 1b included)

### Process lesson

Foundation first: logging and locks before anything that mutates shared state under automation.

---

## Phase 1b — Safety rails

### Goal

Bound concurrency, support TOCTOU-safe deploy later, isolate experiments, and track **executive load** on every daemon tick.

### Implementation process

| Step | What was done |
|------|----------------|
| 1. RWLock | `core/locks/rwlock.sh` — non-blocking try-read; exclusive write; stale writer reclaim |
| 2. Snapshots | `core/snapshot/snapshot.sh` — create / restore / LKG; divergence on goals/inhibitions **or** \|ΔE\| > 0.12 |
| 3. Concurrency + KV | `core/concurrency/semaphore.sh` — max **1** BG inference, contexts ≤ **2**, KV cap **2048** |
| 4. Sandbox | `core/sandbox/sandbox-run.sh` — baseline snapshot → temp WORKSPACE → timeout subprocess → provenance |
| 5. Executive load CLI | `core/executive-load/calc-executive-load.sh` — \(E = 0.06G + 0.12Q + I_{\mathrm{sec}}/25\), clip 1.0 |
| 6. Daemon wiring | `deep-brain-kernel.py` — rolling 10-tick inference window; write `executive-load.json`; if \(E \ge 0.75\) or clipped → defer **spawn** jobs (direct exempt) |
| 7. Harness expansion | Same Phase 1 harness covers semaphore, snapshot, sandbox, rwlock, E formula |

### Outcome

- Safety rails usable as libraries for later phases
- Load reduction is live in the circadian loop

### Process lesson

Put hard resource caps *before* self-modification so ranking and sandbox never assume unlimited inference.

---

## Phase 2 — Executive function + Capability Registry

### Goal

Retrofit **manifests** for all memory skills; add **isolated reflection** and **goal proposal** automation beyond ad-hoc PFC / `reflect.sh` usage.

### Implementation process

| Step | What was done |
|------|----------------|
| 1. Schema in tree | `core/capability-registry.schema.json` |
| 2. Validator | `core/schema/validate-manifest.sh` (`--all` over skills; later also core executive) |
| 3. Manifest authoring | One `capability-manifest.json` per memory skill (11) — `immutable: false`, ≥1 test each |
| 4. Isolated reflection | `core/executive/isolated-reflect.sh` — copy signals to temp tree, chmod read-only analysis, write only to `memory/executive/reflections/`; prove live `pfc-state` hash unchanged |
| 5. Goal proposals | `core/executive/propose-goals.sh` — queue `goal-proposals.jsonl`; optional promote with max-active / min-confidence / **E &lt; 0.75** gate |
| 6. Cycle orchestrator | `core/executive/run-executive-cycle.sh` |
| 7. Daemon entry | Skill `executive-function` + job `executive_goal_cycle` (direct, 1/9/17 :28) |
| 8. Install path | `install.sh` also deploys `core/` so workspace can resolve executive scripts |
| 9. Tests | `tests/run_phase2_harness.sh` (isolation, promote, load gate, manifests, KV contract) |
| 10. Doc path fix | UNIFIED → `AI_BRAIN_SUITE_COMPLETE` in status/AGENTS |

### Outcome

- Registry retrofit complete
- Structured executive loop (offline heuristics; optional inference slot reserved)
- Phase 2 harness **19** pass

### Process lesson

Separate **proposal** from **apply**: reflection never writes PFC; promote is a second, gated step.

---

## Phase 3 — Full self-modification pipeline

### Goal

Canonical experimental loop: **baseline → rank → sandbox eval → graduate → deploy under RWLock → monitor → auto-rollback**, with immutable + registry enforcement.

### Implementation process

| Step | What was done |
|------|----------------|
| 1. Reuse Phase 1b / utility | Weights + `score-utility.sh` already present; thresholds codified in `thresholds.json` |
| 2. Immutable machine list | `immutable-paths.list` + `check-target.sh` (reject decide/locks/sem/sandbox/E-calc/`core/self-mod/**`; require valid manifest) |
| 3. Proposal store | `proposal-store.sh` under `memory/self-mod/proposals/` |
| 4. Pre-sandbox rank | `rank-candidates.sh` — score estimated components, top-K, drop illegal targets |
| 5. Apply abstract | `apply-patch.sh` — full-file `content` or `patch_unified` into a suite root |
| 6. Evaluate | `evaluate-proposal.sh` — copy suite → apply → run regression → utility → threshold + asymmetric graduation (\(U\) must beat baseline) |
| 7. Deploy | `deploy-proposal.sh` — snapshot, file backups, write lock, divergence re-check, apply live, deploy record, provenance |
| 8. Rollback | `rollback.sh` — restore backups + LKG snapshot (git best-effort if `.git` exists) |
| 9. Monitor | `monitor.sh` — compare `live-metrics.json` to deploy baseline; auto-rollback on breach |
| 10. Orchestrator | `run-pipeline.sh` — full pipeline entry |
| 11. Daemon | Job `self_mod_monitor` → `skills/self-mod-runner/scripts/monitor-tick.sh` (pipeline stays on-demand) |
| 12. Tests | `tests/run_phase3_harness.sh` on temp suite (no permanent damage to real tree) |

### Outcome

- End-to-end self-mod path operational under safety rules
- Phase 3 harness **18** pass; Phase 1/2 still green

### Process lesson

Rank **before** expensive sandbox; deploy only after graduation; always keep a backup + LKG so rollback is mechanical, not ad hoc.

---

## Phase 4 — Future (not implemented)

Declared only:

- Meta-learning / evolutionary search
- Full provenance **DAG**
- Cross-session retention (non-core modules only)

No implementation process yet.

---

## Cross-phase verification habit

After each phase (and after combined work):

```bash
cd "/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE"
bash tests/run_phase1_harness.sh   # foundation + safety rails + decide
bash tests/run_phase2_harness.sh   # executive + isolation
bash tests/run_phase3_harness.sh   # self-mod pipeline
bash core/schema/validate-manifest.sh --all
python3 deep-brain-kernel.py --check   # schedule; MISSING paths until install
```

Last full re-run status: **27 / 19 / 21** pass; skill units **11 / 0**; all manifests PASS  
(full local-inference cycle pack: `docs/verification/full_cycle_20260720T234945Z/`).

---

## Dependency picture (why this order)

```text
1a Foundation (locks, schema, provenance, harness)
        ↓
1b Safety (RWLock, snapshot, semaphore, sandbox, E in daemon)
        ↓
2  Registry + executive proposals (isolated reflect → goal queue/promote)
        ↓
3  Self-mod (rank → eval → deploy → monitor/rollback) using 1b+utility+registry
        ↓
4  Future (meta-learning, provenance DAG, retention)
```

---

## Honest residual process gaps (ops / depth)

| Gap | Status (2026-07-21) |
|-----|---------------------|
| Live install to `~/.openclaw/workspace` | **Addressed** for this host — `install.sh` + per-skill installs; `--check` clean when skills present |
| Thin per-skill unit tests | **Addressed** — 11 skill unit tests via `tests/run_skill_unit_tests.sh` |
| LLM proposal generation | **Addressed for local path** — `generate-proposals-llm.sh` + full cycle `prop_8a3f9c1d` generate→rank→eval→deploy→rollback |
| Dual tree `~/AI_BRAIN` | **Resolved** — archived `~/AI_BRAIN.archived-20260720` |
| Task Success 50-tick / sibling Resource Cost | **Still open** — evaluate uses simplified components; weights α/β/γ/δ correct |

Canonical close-out evidence: [verification/full_cycle_20260720T234945Z/CYCLE_REPORT.md](./verification/full_cycle_20260720T234945Z/CYCLE_REPORT.md).
