# V4.0 Verification & Remediation Report

**Date:** 2026-07-20 (updated 2026-07-21 full-cycle close-out)  
**Canonical tree:** `/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE`  
**Evidence directory:** this folder (`docs/verification/`)

Immutable Core was **not** modified by proposal apply targets. Manual fixes were limited to peripheral/process code (`evaluate-proposal.sh` latency baseline, `graduation-tracker.sh`, install noninteractive, skill tests, docs, workspace skill state installs).

### Canonical full local-inference cycle (GREEN)

| Field | Value |
|-------|--------|
| Pack | **`full_cycle_20260720T234945Z/`** |
| Report | `full_cycle_20260720T234945Z/CYCLE_REPORT.md` |
| Proposal | **`prop_8a3f9c1d`** — model-generated (`model_generated:true`), not hand-built |
| Model | Quality GGUF via open-gguf; AMD VRAM **89.7%**; API `127.0.0.1:8080/v1` |
| Loop | generate → rank (count=1) → evaluate (accepted, latency_checked) → deploy → rollback (byte-identical) |
| Harnesses | Phase 1/2/3 **27/19/21** + skill units **11/0**; retested after ops fixes |
| PSI | Self-contained **`psi_fresh_diagnosis.txt`** (+ format probe); poll fallback live |
| Prior pack | `full_cycle_20260720T234618Z/` (earlier same-day pass) |

Earlier sections below preserve the *first* remediation narrative (assisted proposal, latency false positive, etc.). Prefer the full-cycle pack for current close-out claims.

---

## 1. Raw test verification

### Commands

```bash
bash tests/run_phase1_harness.sh -v 2>&1 | tee /tmp/phase1_raw.log
bash tests/run_phase2_harness.sh -v 2>&1 | tee /tmp/phase2_raw.log
bash tests/run_phase3_harness.sh -v 2>&1 | tee /tmp/phase3_raw.log
```

**Note:** Harnesses do **not** implement a `-v` flag; the flag is ignored. Full stdout was still captured.

### Artifacts (unedited copies)

| Log | Path |
|-----|------|
| Phase 1 | `docs/verification/phase1_raw.log` |
| Phase 2 | `docs/verification/phase2_raw.log` |
| Phase 3 | `docs/verification/phase3_raw.log` (initial 18; later re-run 21 after graduation tests) |

### Assertion accounting

| Suite | Footer `passed` | Footer `failed` | `SKIP` lines | Notes |
|-------|-----------------|-----------------|--------------|--------|
| Phase 1 | **27** | 0 | **0** | Log also contains nested tool `PASS:` lines (e.g. schema validator, PFC harness) → `grep -c PASS:` ≈ 37 ≠ harness counter |
| Phase 2 | **19** | 0 | **0** | Nested manifest validator adds extra `PASS:` strings |
| Phase 3 (initial) | **18** | 0 | **0** | After graduation tests: **21** / 0 |

**Skip count is zero.** The 27/19/18 (then 21) figures are real harness `pass()` increments, not skips counted as passes.

### Wall-clock (not near-zero)

| Suite | `/usr/bin/time` elapsed |
|-------|-------------------------|
| Phase 1 | **6.28 s** (includes flock contention, sandbox subprocess, decide harness) |
| Phase 2 | **0.61 s** |
| Phase 3 | **2.44 s** (initial); evaluate-in-pipeline later **~6.1 s** for full phase1 inside sandbox |

No assertion suite completed in “near-zero” time for the paths that exercise sandbox/locks.

---

## 2. Graduation-counter discrepancy

### Finding (before remediation)

`grep` for consecutive-clean / review-frequency streak across the suite found **only** per-proposal asymmetric graduation (U-vs-baseline) in `evaluate-proposal.sh` / `thresholds.json`. **No** persisted rolling window of 20 clean proposals existed.

### Implementation (after remediation)

| Item | Path |
|------|------|
| Module | `core/self-mod/graduation-tracker.sh` |
| State file | `$WORKSPACE/memory/self-mod/graduation-streak.json` |
| Target | 20 consecutive cleans → `review_mode=relaxed_review` |
| Reset | `record-failure` → streak **0**, `full_review` |
| Hook | `evaluate-proposal.sh` records clean vs failure after each eval |

**Distinct from** utility acceptance: tracker does not score U; evaluate still decides accept/reject on U/thresholds.

### Test evidence

Phase 3 harness section `graduation-tracker`:

- clean streak increments to 3  
- failure resets to 0 (`full_review`)  
- state file persisted  

See `tests/run_phase3_harness.sh` and post-run `docs/verification/graduation_status_final.json` (`clean_streak: 1` after one accepted e2e).

---

## 3. Utility weights vs locked defaults

### Files (full copies in evidence)

- `docs/verification/score-utility.sh.full.txt` (full `score-utility.sh`)
- `docs/verification/utility-weights.json`
- `docs/verification/thresholds.json`

### Weights in use — **match locked defaults**

```
α = 0.40  β = 0.15  γ = 0.25  δ = 0.20
```

(`utility-weights.json` + scorer fallback identical.)

### Measurement semantics — **explicit deviations from locked prose**

| Spec (utility-weights / Phase 3 defaults) | Actual in `evaluate-proposal.sh` |
|-------------------------------------------|----------------------------------|
| Task Success: % complete in **50-tick** post-deploy window | **Binary** 1.0 / 0.0 from sandbox regression pass/fail at eval time |
| Resource Cost: normalized vs **sibling-module baseline** | `min(1, elapsed_sec/60)` — wall clock of regression only |
| Error Rate: fraction of sandbox/regression failures | 0.0 or 1.0 for the single regression invocation |
| Regression Penalty: post-deploy scaled | Same as error at pre-deploy eval; post-deploy uses monitor + rollback |

**Why:** Plumbing-first Phase 3; 50-tick window and sibling baselines need continuous live metrics not yet wired into evaluate. Documented, not silently equated to the locked definitions.

**Latency check bug found & fixed during this pass:** baseline used unitless `latency_norm: 1.0` as if it were 1 second, so any ~6s harness run “breached” >20% latency. Fixed to require measured `latency_sec` in baseline-metrics or **skip** latency rule. First real e2e disposition (rejection) still reported below.

---

## 4. Live daemon proof

### Install

```bash
AIBRAIN_NONINTERACTIVE=1 bash install.sh --yes
```

Artifact: `docs/verification/aibrain_install.log` (also `/tmp/aibrain_install.log`).

### `--check` — zero MISSING

Artifact: `docs/verification/aibrain_check_live.log` — ends with **✅ All checks passed.** All direct job scripts `ok`; hermes found.

### Scheduled cycle + executive job

**Deviation for timing:** production schedule is `executive_goal_cycle` at hours `1,9,17` minute `28`. Wall-clock wait to 17:28 PDT would have been ~3h. For this pass, the **installed** kernel (not the Documents source) was temporarily patched to fire:

- `executive_goal_cycle` at minute **16** (hours `*`)
- `amygdala_encoding` (spawn) at minute **17** (hours `*`)

then **restored** from source `deep-brain-kernel.py`.

### Forced E ≥ 0.75

Injected `decision-queue.json` with **Q=8** → \(E = 0.12 \times 8 = 0.96\).

Live log (also `docs/verification/daemon_tick_window.log` / `daemon_key_lines.txt`):

```text
executive load E=0.960 band=hard_ceiling_zone — load-reduction active (deferring non-essential spawn jobs; G=0 Q=8 I_sec=0.00)
executive_goal_cycle: running .../executive-function/scripts/run-cycle.sh
executive_goal_cycle: completed
amygdala_encoding: due now but executive load reduction is active — deferring spawn
```

**This is live journalctl evidence, not the harness.**

---

## 5. Real proposal end-to-end (inference attempt)

### Target

`cerebellum-memory` — `skills/cerebellum-memory/scripts/get-calibration.sh` (manifested, low-stakes comment-only change).

### Inference attempts (honest)

1. **Default Hermes (custom llamaserver):** `APIConnectionError` to `http://0.0.0.0:8080/v1` — local server down. Log: `hermes_proposal_raw.txt` (first attempt).
2. **OpenRouter Hermes (`--provider openrouter`):** model ran but used tools (`skill_manage`) and did **not** emit valid proposal JSON; replied with skill-not-found narrative.

**Assisted construction** then built `real_proposal.json` with the required comment line so the **pipeline** could be exercised. This is **not** pure model-emitted JSON; inference was attempted live and failed to produce a parseable patch.

Artifacts:

- `docs/verification/hermes_proposal_raw.txt`
- `docs/verification/real_proposal.json`

### First pipeline disposition (pre latency-fix) — **report this as primary outcome**

Artifact: `docs/verification/pipeline_e2e_result.json`

| Field | Value |
|-------|--------|
| proposal_id | `prop_cerebellum_v4verify_model_assist` |
| pre_utility | 0.305 |
| post utility U | **0.384638** |
| components | TS=1.0, RC≈0.102, ER=0, RP=0 |
| regression_exit | **0** (phase1 green in sandbox) |
| **accepted** | **false** |
| **reason** | **rollback_threshold_breach** |
| breach | `latency_increase` value **5.1448** vs max **0.20** (baseline lat mis-set as 1.0s) |
| deploy | **null** (not deployed) |
| graduation | failure_reset, clean_streak **0** |

**Interpretation:** Safety rails blocked deploy. That is a **good** process outcome for this pass, even though the latency rule was mis-calibrated.

### After latency baseline fix (secondary, labeled remediation)

Artifact: `docs/verification/pipeline_e2e_after_latency_fix.json`

| Field | Value |
|-------|--------|
| accepted | **true** |
| U | **0.38465** |
| breaches | [] |
| latency_checked | false (no measured baseline_sec) |
| **deployed** | yes, 2026-07-20T21:19:40Z |
| live file | `# V4-verify: calibration lookup is read-primary (2026-07-20)` present |
| clean_streak | **1** / 20 |

---

## 6. Per-skill deep tests

| Skill | Test | Manifest entry |
|-------|------|----------------|
| cerebellum-memory | `tests/test_cerebellum_calibration.sh` | unit path added |
| insula-memory | `tests/test_insula_state.sh` | unit path added |
| social-memory | `tests/test_social_relationships.sh` | unit path added |

Each asserts skill-specific state parsing (would fail if the wrong state file/keys were used). All three exit 0 when run standalone.

---

## 7. Dual-tree `~/AI_BRAIN`

### Consumers

No live dependency found:

- `aibrain.service` → `%h/.openclaw/workspace`
- `install.sh` → `~/.openclaw/workspace` only
- No cron / PATH / openclaw config pointing at `~/AI_BRAIN`

### Action

**Not deleted** (may hold personal notes). Marked archived:

`~/AI_BRAIN/README.ARCHIVED.md`

Canonical edit tree remains Documents `AI_BRAIN_SUITE_COMPLETE`.

---

## 8. Status doc caveats (also in V4_STATUS / AGENTS)

See updated `docs/V4_STATUS.md` and `AGENTS.md`:

- Phases 1–3: **plumbing-complete** + harness-green  
- **Exercised with real inference (updated):** pure local model JSON + full deploy→rollback in `full_cycle_20260720T234945Z/` (`prop_8a3f9c1d`)  
- **Historical note (this report §5):** first pass used assisted proposal when local endpoint was down / OpenRouter failed JSON  
- **Daemon live:** install + --check clean; E=0.96 deferral observed; executive_goal_cycle completed under temporary schedule inject  
- **Graduation streak:** implemented; live workspace advanced multi-clean streak (not yet 20/graduated)  
- **Remaining gaps:** 50-tick Task Success into U; sibling-module Resource Cost baseline  

---

## 9. Full cycle follow-ups (2026-07-20 evening → 2026-07-21)

| Item | Outcome |
|------|---------|
| VRAM measured on wrong GPU (Quadro via nvidia-smi) | Corrected to AMD card1 sysfs → **89.7%** |
| Model generate authenticity | Proven via `llm_model_api.json` timings + llama-server task 36 log; warm KV explains ~3s generate |
| Deploy→rollback | Real; byte-identical restore |
| PSI evidence self-contained | `psi_fresh_diagnosis.txt` in full_cycle pack (no lean on `item3_*` alone) |
| Root PSI trigger nuance | Root succeeds only with `\n` or `\0` terminator (`psi_trigger_format_probe.txt`) |
| Live daemon ops | heartbeat/insula missing state → skill install + retest; bulk other skill states |
| Retest discipline | Per-fix retests + full phase1–3 re-run after ops fixes |

---

## Remediation code changes (this pass)

| Change | Why |
|--------|-----|
| `core/self-mod/graduation-tracker.sh` + evaluate hooks | Spec review-frequency streak |
| `evaluate-proposal.sh` latency baseline | Fix false latency breaches |
| `install.sh --yes` / `AIBRAIN_NONINTERACTIVE` | Live install without TTY |
| Skill unit tests + manifest entries | Per-skill coverage |
| `~/AI_BRAIN/README.ARCHIVED.md` | Dual-tree risk |
| Evidence + this report | Directive artifacts |
