# Stage 3 Readiness Review

**Date:** 2026-08-24
**Auditor:** Buffy (Codebuff agent)
**Scope:** Formal internal audit against VISION.md §6 "Definition of success"
**Purpose:** Go/no-go checkpoint for increasing autonomy tier from Phase 5

---

## VISION.md §6 Definition of Success (verbatim)

> The Suite is succeeding when: the agent's experience is genuinely
> synthesized and persistent (not episodic and stateless); the Suite can
> improve its own capabilities through its own pipeline with measurable,
> rollback-safe gains; and each external-harness function it absorbs makes the
> external harness less necessary — trending toward a self-directed,
> self-improving system that runs without requiring a human in the loop.

---

## Criterion 1: Experience is genuinely persistent (not episodic)

**Verdict: ✅ MET**

| Evidence | Status |
|---|---|
| 15 skill packages with persistent `memory/*.json` state files | ✅ All skills read/write state across daemon ticks |
| Integrative State Layer (neuromod vector, workspace snapshot, broadcast ring) | ✅ Global context persists across cycles |
| Episodic memory (hippocampus encode/decay/consolidate) | ✅ Signals persist in `memory/episodic.jsonl` with cortical theme extraction |
| Semantic knowledge extraction (`extract-patterns.sh`) | ✅ Weekly pattern extraction from episodic store → `semantic-state.json` |
| Verification history (verification-memory) | ✅ Declared-test results persist in `verification-state.json` |
| ACC error lessons | ✅ Confirmed error patterns persist in `acc-lessons.json` |
| Graduation streak | ✅ Clean-streak state persists across daemon restarts |

**Gap:** None. Experience is genuinely persistent across all brain regions and the executive layer.

---

## Criterion 2: Suite can improve its own capabilities with measurable, rollback-safe gains

**Verdict: ✅ MET (with conditions)**

| Component | Status | Evidence |
|---|---|---|
| Self-mod pipeline | ✅ Complete | propose → rank → evaluate → deploy → rollback → monitor → graduation |
| Proposal generation | ✅ LLM-backed | `generate-proposals-llm.sh` with local llama-server, agentloop, or Hermes |
| Proposal ranking | ✅ Signal-driven | Verification failures, ACC lessons, cerebellum calibration boost ranking |
| Proposal arbitration | ✅ Goal-aligned | `arbitrate-proposals.sh` scores against active PFC goals + neuromod |
| Regression gates | ✅ Automated | verification-memory declared-test sweep in sandbox |
| Rollback | ✅ Automated | File restore + snapshot + monitoring |
| Graduation | ✅ Measurable | Clean-streak tracking with explicit targets |
| Autonomy tiers | ✅ Formalized | 4 tiers with machine-readable graduation criteria |
| Chaos resilience | ✅ Tested | PID lock cleanup, state corruption recovery, flock contention |

**Conditions:**
- `LLM_FULL_PATCH=0` (feature flag default OFF) — full-patch proposals must be watched before enabling
- Tier 0 (supervised) is the starting point — graduation requires evidence
- Regression gates are mandatory for every proposal

---

## Criterion 3: External-harness functions absorbed → harness less necessary

**Verdict: ✅ MET**

| Hermes Function | Internalized | Evidence |
|---|---|---|
| Spawn job dispatch | ✅ | `SPAWN_PROVIDER=agentloop` is default |
| Agent reasoning loop | ✅ | `core/agent-loop/agent-loop.sh` with allowlisted tools |
| LLM inference | ✅ | Direct OpenAI-compatible API to local llama-server |
| Proposal generation | ✅ | Local LLM + agentloop provider |
| Goal management | ✅ | `core/executive/` — goals, reflection, arbitration |
| Self-mod pipeline | ✅ | `core/self-mod/` — full pipeline, no hermes |
| Dashboard | ✅ | `core/dashboard/` — shared builder, no hermes |
| Transcript export | ❌ | Reads `~/.hermes/state.db` (data source) |
| Option A cron registration | ❌ | `hermes cron create` (legacy path) |

**Dependency checklist (HERMES_DEPS_CHECKLIST.md):** 19/23 items internalized, 2 optional, 2 require hermes (both legitimate data source / legacy integration).

---

## Criterion 4: Self-directed, self-improving system

**Verdict: ⚠️ PARTIALLY MET — requires observation window**

The infrastructure is complete:
- Proposals can be generated from observed failure patterns (Phase 2)
- Proposals are ranked by measured brain health (Phase 3)
- Proposals are arbitrated against active goals (Phase 4)
- Trust tiers define what autonomous actions are permitted (Phase 5)
- Regression gates prevent regressions (existing)
- Rollback handles failures (existing)

**What's missing:** A real observation window. The system has not yet run through
multiple self-mod cycles with LLM-generated proposals, observed the outcomes,
and demonstrated measurable improvement. The infrastructure is ready, but
the evidence base is thin.

**Recommendation:** Before increasing the autonomy tier, run the system in
Tier 0 (supervised) for at least 2 weeks with `LLM_FULL_PATCH=1` enabled,
observing:
1. Do LLM-generated proposals match what a human would write?
2. Do the regression gates catch real regressions?
3. Does the ranking system correctly prioritize high-impact proposals?
4. Does the rollback system cleanly recover from failed proposals?

---

## Overall Verdict: **CONDITIONAL GO**

The codebase meets 3 of 4 success criteria definitively. The 4th criterion
(self-directed improvement) requires empirical observation that only time
can provide. The system is ready for supervised operation with LLM-generated
proposals — but autonomy tier should remain at Tier 0 until the observation
window produces evidence.

### Recommended next steps

1. **Enable `LLM_FULL_PATCH=1`** and run for 2 weeks in supervised mode
2. **Track proposal quality** — count how many LLM proposals a human would
   have written themselves (target: >70% alignment)
3. **Track regression gate effectiveness** — count how many bad proposals
   the sandbox catches before deployment
4. **After 2 weeks:** if evidence is positive, graduate to Tier 1
   (sandbox_explorer) per the Phase 5 criteria
5. **After 60 days of Tier 1:** if evidence continues positive, graduate
   to Tier 2 (production_deployer)

### What was delivered across Phases 1-7

| Phase | What | Tests |
|---|---|---|
| 1 | `--check-runtime`, systemd integration test, rollback stress test, chaos harness | 28 assertions |
| 2 | `--full-patch` mode, agentloop provider, feature flag | 6 assertions |
| 3 | Verification/error/calibration ranking boosts | 5 assertions |
| 4 | Executive proposal arbitration against goals + neuromod | 5 assertions |
| 5 | 4-tier autonomy ladder with machine-readable criteria | 5 assertions |
| 6 | Hermes dependency audit + checklist | Documentation |
| 7 | Stage 3 readiness review | This document |

**Total new test assertions across Phases 1-7: 49**
**Total test suite: 48/48 pass, 40/40 verification pass**
**ci-gate: 4/4 stages green**
