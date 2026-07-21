# AI Brain Suite V4.0 — Implementation Status

**Project path:** `/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE`  
**Plan source:** *AI Brain Suite V.4.0* (dependency-ordered phases)  
**Note:** Earlier sessions used path name `ai-brain-suite-UNIFIED`; the live tree is `AI_BRAIN_SUITE_COMPLETE`.  
**Process narrative:** [V4_IMPLEMENTATION_PROCESS.md](./V4_IMPLEMENTATION_PROCESS.md)  
**Verification evidence (2026-07-20):** [verification/VERIFICATION_REPORT.md](./verification/VERIFICATION_REPORT.md)  
**Full local-inference cycle (GREEN):** [verification/full_cycle_20260720T234945Z/CYCLE_REPORT.md](./verification/full_cycle_20260720T234945Z/CYCLE_REPORT.md)

### Plumbing vs exercised (honest)

| Layer | State |
|-------|--------|
| Phases 1a–3 code paths | **Plumbing-complete**; harnesses green (27 / 19 / 21, **0 skips**); retested after ops fixes in full cycle |
| Live daemon install | **Exercised** — `install.sh --yes`; `--check` **zero MISSING**; `aibrain.service` active |
| Executive load deferral | **Exercised live** — journal: `E=0.960` + `deferring spawn`; also `E=1.000` clip under heavy `I_sec` during local inference |
| `executive_goal_cycle` | **Exercised live** under temporary installed-kernel minute inject (restored after) |
| Model-generated proposal JSON | **Done (local)** — open-gguf Quality GGUF; pure model JSON `prop_8a3f9c1d` (and earlier `prop_8a7b9c1d` / `prop_a1b2c3d4e5f6`); no hand-build in full cycle |
| Full loop deploy→rollback | **Exercised** — evaluate accepted + deploy marker + rollback byte-identical; evidence under `full_cycle_20260720T234945Z/` |
| Review-frequency clean streak (20) | **Implemented** (`graduation-tracker.sh`); live workspace streak advanced (e.g. 7/20 after multi-eval); not yet graduated |
| Utility component semantics | Weights match α/β/γ/δ; **TS/RC still simplified** vs 50-tick / sibling baseline prose |
| PSI pressure supervisor | **Diagnosed + mitigated** — unprivileged trigger write = EINVAL; root OK with `\n`/`\0` payload; avg10 **poll fallback** armed; self-contained proof in `psi_fresh_diagnosis.txt` |

## Phase 1a — Foundation

| Item | Status | Location |
|------|--------|----------|
| File locking + crash recovery (PID/heartbeat staleness) | **Done** | `core/locks/pid-lock.sh` |
| Schema versioning skeleton | **Done** | `core/schema/schema-registry.json`, `validate-schema.sh` |
| Lightweight provenance logging | **Done** | `core/provenance/log-provenance.sh` |
| Regression harness for decide.sh + core helpers | **Done** | `tests/pfc_decide_harness.sh`, `tests/run_phase1_harness.sh` |

## Phase 1b — Safety Rails

| Item | Status | Location |
|------|--------|----------|
| RWLock + non-blocking reads | **Done** | `core/locks/rwlock.sh` |
| TOCTOU-protected snapshot / divergence check | **Done** | `core/snapshot/snapshot.sh` |
| Concurrency semaphore + KV cache caps | **Done** | `core/concurrency/semaphore.sh` |
| Sandbox harness (subprocess + snapshot) | **Done** | `core/sandbox/sandbox-run.sh` |
| Executive Load formula wired into daemon loop | **Done** | `core/executive-load/calc-executive-load.sh` + `deep-brain-kernel.py` |

## Phase 2 — Executive Function + Capability Registry Retrofit

| Item | Status | Location |
|------|--------|----------|
| Executive goal proposal + isolated reflection | **Done** | `core/executive/{isolated-reflect,propose-goals,run-executive-cycle}.sh` |
| Daemon wiring (direct job, 3× daily) | **Done** | `executive_goal_cycle` → `skills/executive-function/scripts/run-cycle.sh` |
| Capability Registry v1 manifests (11 memory skills + executive) | **Done** | `skills/*/capability-manifest.json`, `core/executive/capability-manifest.json` |
| Manifest schema + validator | **Done** | `core/capability-registry.schema.json`, `core/schema/validate-manifest.sh` |
| Validate against concurrency/KV + test suite | **Done (Phase 2 slice)** | `tests/run_phase2_harness.sh`; skill-specific unit tests for cerebellum/insula/social (others still thin) |

## Phase 3 — Full Self-Modification Pipeline

| Item | Status | Location |
|------|--------|----------|
| Utility Function weights | **Done** | `core/utility/utility-weights.json` |
| Utility scorer | **Done** | `core/utility/score-utility.sh` |
| Immutable target gate + path list | **Done** | `core/self-mod/check-target.sh`, `immutable-paths.list` |
| Proposal store | **Done** | `core/self-mod/proposal-store.sh` |
| Candidate ranking (utility, top-K) | **Done** | `core/self-mod/rank-candidates.sh` |
| Evaluate (sandbox copy + regression + thresholds) | **Done** | `core/self-mod/evaluate-proposal.sh` |
| Deploy (RWLock + divergence + backups) | **Done** | `core/self-mod/deploy-proposal.sh` |
| Rollback + post-deploy monitor | **Done** | `core/self-mod/rollback.sh`, `monitor.sh` |
| End-to-end orchestrator | **Done** | `core/self-mod/run-pipeline.sh` |
| Daemon monitor job | **Done** | `self_mod_monitor` → `skills/self-mod-runner/scripts/monitor-tick.sh` |
| Phase 3 harness | **Done** | `tests/run_phase3_harness.sh` (includes graduation reset-on-failure) |
| Review-frequency graduation (20 clean streak) | **Done** | `core/self-mod/graduation-tracker.sh` + evaluate hooks |
| Live install / daemon | **Verified 2026-07-20** | Evidence under `docs/verification/` |

## Phase 4 — Future

Meta-learning, evolutionary search, full provenance DAG, cross-session retention (non-core only).

## Open gaps (do not delete for cleanliness)

| Gap | Status after full cycle 2026-07-20/21 |
|-----|--------------------------------------|
| Pure model-emitted self-mod JSON via local llamaserver | **Closed** — full cycle `prop_8a3f9c1d` (Quality GGUF, VRAM ~89.7%, open-gguf); rank→eval→deploy→rollback; `model_generated:true`; llama-server timings in log |
| Local deploy→rollback with model JSON | **Closed** — marker `# V4-llm-gen:...` applied then removed; byte-identical to pre |
| PSI EINVAL / pressure supervisor | **Closed (mitigated)** — self-contained `psi_fresh_diagnosis.txt`; poll-mode fallback live |
| Workspace skill state completeness | **Closed for this host** — missing heartbeat/insula/etc. states fixed via skill `install.sh`; direct jobs retested |
| Task Success as 50-tick post-deploy % | Still binary at evaluate-time; monitor window exists but not wired into U |
| Resource Cost vs sibling-module baseline | Still `elapsed/60` proxy |
| Per-skill unit tests for remaining skills | **Resolved 2026-07-20:** 11 skill-specific unit tests via `tests/run_skill_unit_tests.sh` |
| `~/AI_BRAIN` dual tree | **Resolved 2026-07-20:** fully superseded; moved to `~/AI_BRAIN.archived-20260720`; pointer `~/AI_BRAIN.path-moved`. No live cron/systemd refs. |
| Harness `-v` flag | Not implemented (flag ignored; full logs still captured) |


## Residual-gap worklog

### 2026-07-20 — Step 1: Duplicate tree

- Diffed `~/AI_BRAIN` vs `AI_BRAIN_SUITE_COMPLETE`: **0** files newer-and-different in old tree; only unique file was `README.ARCHIVED.md`.
- Canon has all Phase 2/3/executive/self-mod/tests missing from old tree.
- No systemd/cron/config runtime dependency on `~/AI_BRAIN` (only Hermes chat history logs).
- **Action:** `mv ~/AI_BRAIN ~/AI_BRAIN.archived-20260720`; wrote `~/AI_BRAIN.path-moved`.


### 2026-07-20 — Step 2: Live scheduler

- V4 live scheduler is **`deep-brain-kernel.py` via `aibrain.service`**, not legacy `legacy-IGNORE/brain-daemon.sh`.
- Re-ran `AIBRAIN_NONINTERACTIVE=1 install.sh --yes` from `AI_BRAIN_SUITE_COMPLETE`; `--check` **0 MISSING**; all 11 memory skills + executive-function + self-mod-runner present under `~/.openclaw/workspace/skills/`.
- **User crontab empty** — no per-skill cron entries to remove (already superseded by systemd unit).
- Service **active (running)**; `--status` shows recent fires (`vta_encoding` OK, `executive_goal_cycle` OK). Journal shows live tick + spawn activity.
- Evidence: `docs/verification/step2_check_after_restart.log`, `step2_journal_after_restart.log`.


### 2026-07-20 — Step 3: Per-skill unit tests

- Weakest coverage was the 8 skills that only pointed at `tests/run_phase1_harness.sh` (shared harness).
- Added skill-isolated unit tests for: hippocampus, amygdala, vta, basal-ganglia, anterior-cingulate, acc-error, heartbeat, prefrontal-cortex (plus existing cerebellum/insula/social).
- Runner: `tests/run_skill_unit_tests.sh` — **11 passed, 0 failed**.
- Manifests updated with unit test paths.


### 2026-07-20 — Step 4: LLM self-mod proposals

- Added `core/self-mod/generate-proposals-llm.sh` (Hermes inference → JSON proposal → `check-target` → proposal store).
- Wired `run-pipeline.sh --generate-llm [--llm-module] [--llm-provider]`.
- Allowlist: only `skills/*/capability-manifest.json` with `immutable:false`; hard reject Immutable Core paths.
- Live proof: OpenRouter/auto generated `prop_cerebellum_memory_install_comment_v1` for `skills/cerebellum-memory/install.sh`; check-target OK; rank pre_U=0.366; evaluate **accepted** (U≈0.385, regression 0). Evidence under `docs/verification/llm_*`.
- Parser hardened for Hermes box line-wrapping of JSON strings.


### Schema note — habit-state.json `.habits` (2026-07-20)

**Canonical shape is an array of habit objects**, not an object keyed by habit id.

Evidence (pre-existing design + producers, not a unilateral test invention):
- `skills/basal-ganglia-memory/SKILL.md` schema: `"habits": [ { "id", "cue", ... } ]`
- `skills/basal-ganglia-memory/ARCHITECTURE.md`: `habits[]`
- `install.sh` initializes `"habits": []`
- Producers/consumers: `reinforce-habit.sh`, `load-habits.sh`, `get-habits.sh`, `decay-habits.sh`, `sync-state.sh`, `encode-pipeline.sh`, `generate-dashboard.sh` all use list iteration / `h.get(...)`
- Cross-skill: `prefrontal-cortex-memory/scripts/decide.sh` uses `jq '([.habits[].strength] | ...)'` (array stream)

**Incident:** an early draft of `tests/test_basal_ganglia_habits.sh` briefly used object-keyed `"habits": {"morning_review": {...}}`. Production would AttributeError on `h.get` if fed that shape. Fixture was corrected to array before any live schema rewrite. **No production scripts were changed** — they already expected arrays.

**Standing rule:** fixture shape changes require a consumer audit before more tests.


### Naming (live vs legacy)

| Name | Status |
|------|--------|
| `deep-brain-kernel.py` + `aibrain.service` | **Live** scheduler/pressure supervisor |
| `legacy-IGNORE/brain-daemon.sh` | **Legacy** bash daemon — not used by install |

Do not say "brain-daemon" when referring to the running service.


### 2026-07-20 — Close-out (local Quality GGUF)

1. **Local LLM proposal (not OpenRouter):** `open-gguf` profile `apex-mtp-i-quality` for
   `Carnice-Qwen3.6-MoE-35B-A3B-APEX-MTP-I-Quality.gguf` — VRAM **~89.7%**. Proposal via
   local `http://127.0.0.1:8080/v1` (`prop_local_9a3f2e`). Hermes agent min-ctx was set to 70k;
   generation used OpenAI-compatible local API when Hermes CLI timed out.
2. **Deploy + rollback:** evaluate **accepted** → deploy wrote `# V4-local-verify` →
   rollback restored prior file (marker removed). Evidence: `docs/verification/local_*.json`.
3. **Naming:** Live engine documented as `deep-brain-kernel.py` / `aibrain.service` in
   AGENTS, V4_STATUS, README, BRAIN_DAEMON_SCHEDULE header.
4. **PSI:** Root cause = unprivileged write to `/proc/pressure/*` returns **EINVAL** on
   Ubuntu 6.8 (CONFIG_PSI=y; root write succeeds). Fixed: poll-mode avg10 fallback in
   `deep-brain-kernel.py` so PSI still drives deferral without root.

**Model load rule:** use `open-gguf` for this host; refuse verification if VRAM << intended band.


### 2026-07-20 — Open items closed (model-generated + rollback + PSI + latency)

1. **Local inference proposal (no hand-build):** Local llama-server via open-gguf
   Quality GGUF (VRAM ~89.6%). `generate-proposals-llm.sh` uses OpenAI API at
   `127.0.0.1:8080` with insert_lines schema. Model raw JSON in
   `docs/verification/item1_model_raw_final.txt` / `item1b_model_raw.txt`;
   parsed `prop_8a7b9c1d` with `model_generated:true`.
2. **Rollback proven:** Deploy inserted `# V4-llm-gen:...`; rollback removed it.
   Evidence `item2_*`.
3. **Latency check re-enabled:** evaluate measures/stores `latency_sec` baseline
   (measured ~6.16s); `latency_checked:true` on e2e.
4. **PSI:** Unprivileged trigger write = EINVAL; root OK. Poll-mode fallback in
   deep-brain-kernel.py. Evidence `item3_psi_investigation.txt`.


### 2026-07-20/21 — Full local inference cycle (GREEN, self-contained pack)

**Evidence:** `docs/verification/full_cycle_20260720T234945Z/`  
**Report:** `docs/verification/full_cycle_20260720T234945Z/CYCLE_REPORT.md`

| Gate | Result |
|------|--------|
| AMD VRAM (card1, not nvidia-smi Quadro) | **89.7%** (80–94% Quality band) |
| Phase 1 / 2 / 3 | 27/0, 19/0, 21/0 — then **retest** after ops fixes still green |
| Skill units | 11/0 (+ retest after skill state install) |
| Manifests / daemon | 14 manifests; `aibrain` active; `--check` OK |
| LLM generate | **Fresh** `prop_8a3f9c1d` via local OpenAI API; raw `raw_20260720T235105Z.txt`; 104 completion tokens; llama task timings match API (~2.8s warm KV) |
| Rank | Non-empty (count=1) |
| Evaluate | accepted U≈0.385; **latency_checked=true**; latency_sec≈6.15 |
| Deploy → rollback | Marker present → removed; **byte-identical** to pre |
| No OpenRouter | `LLM_LOCAL_ONLY=1`; Quality GGUF in API model id |
| Immutable core | `scripts/decide.sh` + `rwlock.sh` → `immutable_core` |
| PSI self-contained | `psi_fresh_diagnosis.txt` + `psi_trigger_format_probe.txt` (user always EINVAL; root OK with `\n`/`\0`) |
| Ops defects found & fixed | Missing `heartbeat-state.json`, insula not installed → skill `install.sh` + retests |

**Hold-to notes (post-cycle review):** generate was real inference (not hand-built); speed explained by prompt KV cache + short JSON; full harness re-run after each ops fix class.

## Verify

```bash
cd "/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE"
bash tests/run_phase1_harness.sh
bash tests/run_phase2_harness.sh
bash tests/run_phase3_harness.sh
bash tests/run_skill_unit_tests.sh
bash core/schema/validate-manifest.sh --all
WORKSPACE="$HOME/.openclaw/workspace" python3 deep-brain-kernel.py --check
# Full-cycle evidence (canonical close-out pack):
#   docs/verification/full_cycle_20260720T234945Z/CYCLE_REPORT.md
#   docs/verification/VERIFICATION_REPORT.md
```
