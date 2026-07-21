# Full Local Inference Cycle Report

- **Evidence dir:** `/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE/docs/verification/full_cycle_20260720T234945Z`
- **UTC start:** 2026-07-20T23:49:45Z
- **UTC final:** 2026-07-20T23:53:12Z
- **Model:** Carnice-Qwen3.6-MoE-35B-A3B-APEX-MTP-I-Quality.gguf via open-gguf (Vulkan AMD RX 5700 XT)
- **AMD VRAM:** 89.7% (gate 80–94%) — PASS
- **Local API:** http://127.0.0.1:8080/v1 — healthy
- **LLM_LOCAL_ONLY:** 1 (no OpenRouter)
- **Proposal (fresh model JSON):** `prop_8a3f9c1d` raw `raw_20260720T235105Z.txt`

## Verdict

**GREEN after debug loop.**

Primary stack (harnesses + LLM pipeline) was green on first full pass. Live-daemon operational failures (missing skill state) were found during journal audit, fixed via skill `install.sh`, and retested successfully. Harnesses re-run after fixes: Phase1 27/0, Phase2 19/0, Phase3 21/0. Failures file empty.

## Primary stack

| Check | Result |
|-------|--------|
| VRAM gate (AMD card1) | PASS 89.7% |
| Health | PASS |
| Phase 1 | PASS 27/0 (retest PASS) |
| Phase 2 | PASS 19/0 (retest PASS) |
| Phase 3 | PASS 21/0 (retest PASS) |
| Skill units | PASS 11/0 (retest after install PASS) |
| Manifests | PASS |
| aibrain.service | active |
| deep-brain-kernel --check | PASS |
| PSI poll fallback | journal evidence EINVAL → avg10 poll |
| Immutable decide/rwlock | reject immutable_core |
| LLM generate | PASS prop_8a3f9c1d model_generated |
| Rank | PASS count=1 non-empty |
| Evaluate | accepted U≈0.385 latency_checked=true latency_sec≈6.15 |
| Deploy | `# V4-llm-gen` marker present |
| Rollback | marker removed; byte-identical to pre |
| No OpenRouter | PASS |

## Debug loop (ops defects found & fixed)

| Defect | Evidence | Fix | Retest |
|--------|----------|-----|--------|
| `heartbeat_beat` exit 1 — no heartbeat-state.json | journal ERROR every :07/:37 | `skills/heartbeat-memory/install.sh` | beat --dry-run rc=0; unit PASS |
| `insula_encoding` exit 1 — Not installed | journal 14:40 | `skills/insula-memory/install.sh` | encode-pipeline rc=0 |
| Other skill states missing in workspace | audit MISSING | bulk install amygdala/hippocampus/vta/basal/social/cerebellum/acc/pfc | direct job smokes OK; skill units 11/0 |

## Notes (procedure / operational)

NOTE: earlier aibrain_active FAIL was test-script unquoted path with spaces; service is active
NOTE: initial immutable test used wrong path (skill root decide.sh missing); correct path scripts/decide.sh is immutable_core
NOTE: first generate attempt used wrong path (missing scripts/); aborted before inference. Stale raw prop_a1b2c3d4e5f6 was NOT accepted as this cycle's evidence.
NOTE: failures.txt had false FAIL for wrong decide.sh path (no scripts/); correct scripts/decide.sh is immutable_core — cleared from failures.
NOTE: live daemon ERROR heartbeat_beat missing heartbeat-state.json — fixed by skills/heartbeat-memory/install.sh
NOTE: live daemon ERROR insula_encoding 'Not installed' — fixed by skills/insula-memory/install.sh
NOTE: bulk install of other skill state files (amygdala/hippocampus/vta/basal/social/cerebellum/acc/pfc) for workspace completeness
NOTE: executive load E=1.000 clipped often when I_sec high from local inference (intended load-reduction)

## Passes

```
OK: model_vram 89.7
OK: health
OK: phase1
OK: phase2
OK: phase3
OK: skill_units
OK: manifests
OK: daemon_check
OK: aibrain_active
OK: psi_fallback_logged_or_active
OK: immutable_rwlock_rejected
OK: mutable_cerebellum_allowed
OK: immutable_decide_rejected
OK: llm_generate
OK: llm_raw_is_json
OK: rank_nonempty
OK: evaluate_accepted
OK: latency_checked
OK: deploy
OK: deploy_marker_present
OK: rollback
OK: rollback_marker_removed
OK: rollback_byte_identical_to_pre
OK: no_openrouter_in_local_gen
OK: quality_model_in_api
OK: proposal_model_generated_not_handbuilt
OK: retest_cerebellum_after_rollback
OK: heartbeat_beat_after_state_init
OK: retest_heartbeat_unit
OK: insula_encode_after_install
OK: skill_units_after_state_init
OK: retest_phase1
OK: retest_phase2
OK: retest_phase3
OK: direct_jobs_smoke_after_install
```

## Failures

```
(none)
```

## PSI self-contained proof (follow-up)

Fresh capture in-folder: **`psi_fresh_diagnosis.txt`** — unprivileged `/proc/pressure/*` read OK; trigger write **EINVAL**; journal shows poll fallback; no dependency on `item3_psi_investigation.txt`.
