# AI Brain Suite — Project Rules

**Project root (do not relocate):** the root of this repository checkout.
In the live deployment the suite runs from the agent's own workspace,
deployed from this tree; exactly one instance runs on real state.

Global reasoning protocol and safety rules live outside this repo. This
file adds project-local constraints.

> **Dated update (2026-11-25):** this file previously described
> `deep-brain-kernel.py` as the live engine and the bash daemon as legacy.
> In the current deployment that is reversed: the live scheduler is
> **`brain-daemon.sh`** under **`aibrain.service`**, with
> **`helm-keeper.service`** running `bin/helm-keeper`. The roster is 19
> organ skills. Sections below are corrected accordingly; the standing
> rules (immutable core, fixture discipline) are unchanged.

## Immutable Core (never self-modify)

- `skills/prefrontal-cortex-memory/scripts/decide.sh`
- `core/locks/rwlock.sh`, `core/locks/pid-lock.sh`
- `core/concurrency/semaphore.sh`
- `core/sandbox/sandbox-run.sh`
- `core/executive-load/calc-executive-load.sh`
- Self-modification pipeline (Phase 3; when present under `core/self-mod/`)

Only peripheral modules with a valid `capability-manifest.json` are modifiable.

## Layout

| Path | Role |
|------|------|
| `brain-daemon.sh` | **Live scheduler** — 25-job table, PSI backpressure, `--check` validation mode |
| `deep-brain-kernel.py` | Python engine from the September line (async scheduler + pressure supervisor); in the tree, not the engine running in the current deployment |
| `bin/helm-keeper` | Keeper: merges results-drop answers into both result directories, maintains helm health (queue depth, deadletters) |
| `systemd/` | Unit sources: `aibrain.service` (daemon), `helm-keeper.service` (keeper), plus shadow variants for cutover testing |
| `core/` | Foundation (locks, schema, provenance, load, concurrency, snapshot, sandbox, executive) |
| `core/gate/` | Conversation wire + signal gate support: `envelope.py` (turn ingress), `flows.json` (flow registry), wire design doc |
| `core/executive/` | Isolated reflection + goal proposal cycle |
| `core/self-mod/` | Self-mod pipeline (immutable as proposal target) |
| `core/self-mod/generate-proposals-llm.sh` | LLM → proposal store (manifest allowlist only) |
| `core/self-mod/acc-calibration.sh` | ACC flag→error calibration (Stage-1 proprioception): hit rate of flagged uncertainty predicting real errors; feeds `health-context.sh` |
| `core/agent-loop/` | Internal agentic loop: multi-turn tool use + session memory against the local LLM; `SPAWN_PROVIDER=agentloop` |
| `core/dashboard/` | Shared dashboard builder (assembles per-organ fragments into `brain-dashboard.html`) |
| `scripts/` | `serve-dashboard.sh` + `dashboard-server.py` (live dashboard serve), `ci-gate.sh`, `deep-verify.sh` |
| `tests/run_skill_unit_tests.sh` | Per-skill unit suite (incl. verification-memory self-test) |
| `skills/` | The 19 organ skills (memory/cognition organs + executive-function + self-mod-runner + verification-memory + immune-system-memory) |
| `skills/verification-memory/` | **Verification region (proprioception):** manifest-driven runner of every module's declared tests; publishes `tests_passed`/`test_failure` signals; self-mod's `evaluate-proposal.sh` runs it as the pre-deploy regression gate |
| `tests/test_verification_region.sh` | verification-memory self-test (gates the gate) |
| `tests/run_phase1_harness.sh` | Phase 1a/1b regression suite |
| `tests/run_phase2_harness.sh` | Phase 2 executive / isolation regression suite |
| `tests/run_phase3_harness.sh` | Phase 3 self-mod pipeline regression suite |
| `tests/pfc_decide_harness.sh` | decide.sh closed-loop assertions |
| `docs/V4_STATUS.md` | Phase completion tracker (plumbing vs live-exercised caveats) |
| `docs/V4_IMPLEMENTATION_PROCESS.md` | How each phase was implemented (process narrative) |
| `docs/verification/` | Raw harness logs, daemon journals, e2e pipeline evidence |
| `docs/verification/full_cycle_20260720T234945Z/` | **Canonical GREEN full local-inference cycle** (generate→rank→eval→deploy→rollback + PSI self-contained proof) |
| `docs/verification/VERIFICATION_REPORT.md` | Verification ledger (historical + full-cycle pointer) |
| `core/self-mod/graduation-tracker.sh` | Review-frequency clean streak (20); reset-on-failure |
| `core/provenance/log-provenance.sh` | Per-patch DAG + generic `event`/`events` audit trail; `log-provenance.sh events --filter autonomy` shows every autonomy decision |

## Concurrency / KV

- Max 1 concurrent background inference; total contexts ≤ 2
- Background KV cache hard cap: 2048 tokens
- Non-inference ops exempt

## Before claiming a phase done

Run:

```bash
bash brain-daemon.sh --check   # live job table: script paths + minute uniqueness
bash scripts/ci-gate.sh   # one-command replay of the CI Verification Gate
bash tests/run_phase1_harness.sh
bash tests/run_phase2_harness.sh
bash tests/run_phase3_harness.sh
bash core/schema/validate-manifest.sh --all
bash skills/verification-memory/scripts/run-declared-tests.sh   # full manifest-driven sweep
```

For the **live deployment**, "done" additionally means the heartbeat card
passes (11/11) and the heartbeat regression suite holds (58/58 as of
2026-11-25) — see `CURRENT_STATE.md`. A green unit suite does not by
itself prove the running harness is healthy; the card measures the
running harness.

## Verification region fixture rule

Since `run-declared-tests.sh` parses `capability-manifest.json` `tests` entries
(path + kind), a change to that manifest shape means auditing
`skills/verification-memory/scripts/run-declared-tests.sh` and
`tests/test_verification_region.sh` **before** the manifest change lands. A
passing verification self-test only proves the runner agrees with its own
fixture — the standing fixture rule applies to the verification region itself.

## Live scheduler (naming) — corrected 2026-11-25

The live engine is **`brain-daemon.sh`** under **`aibrain.service`**,
with **`bin/helm-keeper`** under **`helm-keeper.service`** (unit sources
in `systemd/`). `deep-brain-kernel.py` ships in this tree as the
September-line engine and is not the running scheduler in the current
deployment. The earlier version of this section said the opposite; it
described the September tree and is superseded.

Process counting rule for anything that checks liveness: count
**top-level processes only** (exact argv match). The daemon and keeper
spawn children; a naive process count mistakes children for duplicate
daemons — that exact miscount has already caused one false alarm and is
guarded in the regression suite.

## Test fixture standing rule

If a test change alters a **fixture data shape** (not just values), stop and audit every real consumer of that structure before more test files. A passing test only proves the test agrees with its own fixture — not with production.

## Local model load rule

For local GGUF inference tests, load models with the machine’s proper launcher (`open-gguf` for this host), never a stripped-down/`--cpu-moe`-only shortcut that leaves VRAM far below the model’s intended footprint. Confirm VRAM is in the expected band **before** running verification that depends on the model.

On this host, measure **AMD RX 5700 XT** VRAM via `/sys/class/drm/card1/device/mem_info_vram_{used,total}` (Quality band ~80–94%). Do **not** use `nvidia-smi` alone (Quadro K600 is the display card and will report ~30% and look like a failed Quality load).

## PSI on this host

Unprivileged write of a PSI **trigger** to `/proc/pressure/*` returns **EINVAL** (reads OK; `CONFIG_PSI=y`). Root can arm triggers when the payload is newline- or NUL-terminated. `deep-brain-kernel.py` falls back to **avg10 poll mode**. Self-contained proof: `docs/verification/full_cycle_20260720T234945Z/psi_fresh_diagnosis.txt`.
