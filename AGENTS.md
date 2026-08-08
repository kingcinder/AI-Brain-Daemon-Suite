# AI Brain Suite — Project Rules (V4.0)

**Project root (do not relocate):**  
`/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE`

Global reasoning protocol and V4.0 safety rules live in `~/.grok/AGENTS.md`. This file adds project-local constraints.

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
| `deep-brain-kernel.py` | Scheduler + pressure supervisor; executive load wired each tick |
| `core/` | V4.0 foundation (locks, schema, provenance, load, concurrency, snapshot, sandbox, executive) |
| `core/executive/` | Phase 2 isolated reflection + goal proposal cycle |
| `core/self-mod/` | Phase 3 self-mod pipeline (immutable as proposal target) |
| `core/self-mod/generate-proposals-llm.sh` | LLM → proposal store (manifest allowlist only) |
| `core/self-mod/acc-calibration.sh` | ACC flag→error calibration (Stage-1 proprioception): hit rate of flagged uncertainty predicting real errors; feeds `health-context.sh` |
| `core/agent-loop/` | Internal agentic loop (AUDIT Gap 2 follow-on): multi-turn tool use + session memory against the local LLM; `SPAWN_PROVIDER=agentloop` |
| `tests/run_skill_unit_tests.sh` | Per-skill unit suite (12 skills incl. verification-memory self-test) |
| `skills/` | Peripheral modules (memory skills + executive-function + self-mod-runner + verification-memory) |
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
bash scripts/ci-gate.sh   # one-command replay of the CI Verification Gate
bash tests/run_phase1_harness.sh
bash tests/run_phase2_harness.sh
bash tests/run_phase3_harness.sh
bash core/schema/validate-manifest.sh --all
bash skills/verification-memory/scripts/run-declared-tests.sh   # full manifest-driven sweep
```

## Verification region fixture rule

Since `run-declared-tests.sh` parses `capability-manifest.json` `tests` entries
(path + kind), a change to that manifest shape means auditing
`skills/verification-memory/scripts/run-declared-tests.sh` and
`tests/test_verification_region.sh` **before** the manifest change lands. A
passing verification self-test only proves the runner agrees with its own
fixture — the standing fixture rule applies to the verification region itself.

## Live scheduler (naming)

The live engine is **`deep-brain-kernel.py`** under **`aibrain.service`** (systemd `--user`).  
`legacy-IGNORE/brain-daemon.sh` is **legacy only** and is not installed by `install.sh`.  
Do not call the running service “brain-daemon.”

## Test fixture standing rule

If a test change alters a **fixture data shape** (not just values), stop and audit every real consumer of that structure before more test files. A passing test only proves the test agrees with its own fixture — not with production.

## Local model load rule

For local GGUF inference tests, load models with the machine’s proper launcher (`open-gguf` for this host), never a stripped-down/`--cpu-moe`-only shortcut that leaves VRAM far below the model’s intended footprint. Confirm VRAM is in the expected band **before** running verification that depends on the model.

On this host, measure **AMD RX 5700 XT** VRAM via `/sys/class/drm/card1/device/mem_info_vram_{used,total}` (Quality band ~80–94%). Do **not** use `nvidia-smi` alone (Quadro K600 is the display card and will report ~30% and look like a failed Quality load).

## PSI on this host

Unprivileged write of a PSI **trigger** to `/proc/pressure/*` returns **EINVAL** (reads OK; `CONFIG_PSI=y`). Root can arm triggers when the payload is newline- or NUL-terminated. `deep-brain-kernel.py` falls back to **avg10 poll mode**. Self-contained proof: `docs/verification/full_cycle_20260720T234945Z/psi_fresh_diagnosis.txt`.

