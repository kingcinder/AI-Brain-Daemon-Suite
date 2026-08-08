---
name: verification-memory
description: "The brain's proprioception — a verification region that runs every other module's declared tests from their capability manifests, reports a green/red felt state onto the signal bus, and feeds failures into the error/emotion systems. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🩺"
    tags: ["memory", "verification", "ai-brain", "testing", "proprioception"]
  openclaw:
    emoji: "🩺"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/verification-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["bash", "jq"]
    tags: ["memory", "verification", "ai-brain", "testing"]
---

# Verification 🩺

**The sense that every other region is still working.** Part of the AI Brain series.

Every other skill in the brain suite is a memory/decision region. This one is
**proprioception**: it periodically asks "do all my limbs still move the way
they said they would?" and answers with a felt state the rest of the brain can
react to — reward when green, frustration + error-pattern analysis when red.

## Why it exists

The suite's regression harnesses (`tests/run_phase*_harness.sh`, the
`tests/test_*.sh` unit tests) are the one part of the brain that sits outside
the brain. They have no module, no manifest, no signal routes — nothing
consumes their results. This skill closes that gap without touching the
harnesses themselves: **it reads the `tests` array each module already declares
in its `capability-manifest.json` and runs exactly what was declared.**

The `tests` field is not new plumbing — every peripheral module already has
one. Today it's metadata nobody reads. Verification-memory makes it the
interface.

## When to Use

Use this skill when:
- You want a full-suite regression sweep driven by the manifests, not by a
  hardcoded list of harness filenames
- You want a single region to verify itself (`--module <name>`) on demand
- You want test results to *mean* something in the brain: green → VTA reward,
  red → ACC error patterns + amygdala frustration
- You're the daemon and want a `verification_pass` job that fails loudly when
  any declared test breaks
- You're the self-mod pipeline and want every proposal regression-gated against
  the full declared-test surface before it deploys
- You want a PR gate: the same manifest-driven sweep that runs locally blocks
  merges in CI

Not for: writing the tests themselves (those stay where they are).

## Status: ✅ Live

## How it works

1. **Discover** — walk `skills/*/capability-manifest.json` +
   `core/executive/capability-manifest.json` (the same set
   `validate-manifest.sh --all` checks).
2. **Parse** — each manifest's `tests` array yields
   `{path, kind}` (e.g. `tests/run_phase2_harness.sh`, kind `regression`).
3. **Run** — execute every declared test, deduplicated, with a per-test
   timeout, capturing pass/fail and exit codes.
4. **Record** — write `memory/verification-state.json` +
   `memory/verification-report.jsonl` (append-only ledger).
5. **Publish** — emit `tests_passed` or `test_failure` onto the signal bus so
   the routing table turns results into felt states (see below).
6. **Report** — regenerate `VERIFICATION_STATE.md` and the dashboard fragment.

### Manifest-driven discovery (the "equal ease" lever)

Add *any* test to *any* module's manifest and it becomes part of the next
verification pass. Zero per-region wiring — the manifest is the interface, this
skill is the reader, exactly the pattern `validate-manifest.sh --all` already
uses. That is the literal answer to "interwoven with equal ease": there is no
verification-specific registry to keep in sync.

Every phase harness in the suite is now declared where it belongs: phase1 →
acc-error/heartbeat/hippocampus/etc., phase2/5/6 → executive-function, phase3/4
→ self-mod-runner, phase7 → hippocampus, plus each module's own unit tests. So
a full sweep covers the entire regression surface — nothing is CI-only.

## Quick Start

```bash
# Full sweep over every module's declared tests
./scripts/run-declared-tests.sh

# Just one module's declared tests (also the signal-triggered entry point)
./scripts/run-module-tests.sh --module acc-error-memory

# List what the manifests declare without running anything
./scripts/run-declared-tests.sh --list
```

## Scripts

| Script | Purpose |
|---|---|
| `run-declared-tests.sh` | Full sweep: discover manifests → run declared tests → record → publish → report. |
| `run-module-tests.sh` | Targeted: run one module's declared tests (`--module <name>`), with a cooldown so signal storms don't spam the suite. |
| `sync-state.sh` | Regenerate `VERIFICATION_STATE.md` + dashboard fragment from `verification-state.json`. |
| `generate-dashboard.sh` | Write this skill's "🩺 Verification" dashboard fragment (incl. long-term health sparkline + healthiest/unhealthiest region + the autonomy contract history timeline — when/why `auto_mode` was granted or revoked, live-refreshed from `/__daemon`). |
| `query-history.sh` | Long-term health query over `verification-report.jsonl`: per-module pass-rate history, sparkline-ready points, healthiest/unhealthiest region. |
| `backfill-history.sh` | Seed the report ledger with N historical runs (derived from the real full-sweep result) so the 🩺 sparkline shows a trend immediately. |
| `log-event.sh` | Append to the shared `brain-events.jsonl`. |
| `dashboard-builder.sh` | Shared AI Brain Series dashboard assembler (identical copy, per the suite convention). |

## Signal Routes

Registered in `core/signaling/route-signals.sh` — the ONE place for
cross-module coupling, same as every other skill:

**Inbound** (a module's signals re-trigger its own declared tests):
```
prefrontal-cortex-memory|goal_promoted|verification-memory|scripts/run-module-tests.sh|--module {source}
cerebellum-memory|calibration_drift|verification-memory|scripts/run-module-tests.sh|--module {source}
hippocampus-memory|significant_memory|verification-memory|scripts/run-module-tests.sh|--module {source}
heartbeat-memory|action_chosen|verification-memory|scripts/run-module-tests.sh|--module {source}
acc-error-memory|pattern_resolved|verification-memory|scripts/run-module-tests.sh|--module {source}
```

**Outbound** (results become felt states, exactly like the amygdala→vta wiring).
gate.sh word-splits arg templates, so args are single tokens;
`{payload_pattern}` carries the failing `owner:path` from the publish payload:
```
verification-memory|tests_passed|vta-memory|scripts/log-reward.sh|--type competence --intensity 0.4 --source all_declared_tests_green
verification-memory|test_failure|acc-error-memory|scripts/log-error.sh|--pattern {payload_pattern} --context verification_failure
verification-memory|test_failure|amygdala-memory|scripts/update-state.sh|--emotion frustration --intensity {intensity} --trigger test_failure
```

A green suite is *rewarding*. A red suite gets pattern-analyzed like any other
error and lands as frustration in the amygdala. That closes the loop: the
brain now feels its own health.

## State

`memory/verification-state.json` — `lastRun`, `totals` (tests/passed/failed/
skipped), per-module results, `lastFailure` detail.

`memory/verification-report.jsonl` — append-only per-run ledger (timestamp,
totals, failed paths) for long-term trend.

`VERIFICATION_STATE.md` — human-readable summary, regenerated by
`sync-state.sh`, for context injection.

## Long-Term Health

Every run appends to `memory/verification-report.jsonl` — and because the ledger
carries a per-module breakdown (`modules: {owner: {tests, passed, failed}}`), the
region can answer "is this region getting healthier over time?":

```bash
# JSON (programmatic + dashboard use)
./scripts/query-history.sh
# Human-readable trend table with per-region sparkline glyphs
./scripts/query-history.sh --text
# One region only, last N runs each
./scripts/query-history.sh --module acc-error-memory --limit 12
```

The query returns overall + per-module pass-rate history (old ledger entries
without a `modules` field still count toward the overall trend).

### Seeding the trend (backfill)

On a fresh workspace the ledger has zero or one entry, so the sparkline renders
a single bar until the daily `verification_pass` job has run for days. To make
the trend visible immediately:

```bash
./scripts/backfill-history.sh            # seed the past 7 days from the real sweep result
./scripts/backfill-history.sh --days 14  # seed two weeks instead
```

Every backfilled entry is derived from the **most recent real full-sweep entry**
already in the ledger (`filter=all`, with its per-module breakdown) — no
pass/fail data is invented. Only the timestamps are historical, stamped at the
daemon's scheduled `verification_pass` minute (07:56 UTC), and each entry
carries `"source":"backfill"` so the ledger stays auditable. The ledger is
rebuilt atomically (backfill entries chronological, then originals unchanged)
with a timestamped backup kept alongside; a day that already has an entry is
never double-filled, and a second run without `--force` is a no-op. The script
refuses (exit 1) if there's no ledger or no full-sweep entry to derive from —
run a sweep first in that case. The overall
trend spans every run — full sweeps and signal-triggered `--module` re-checks
alike — while each module's rate is scoped to that region's own runs. It names the
**healthiest / unhealthiest region** — regions seen in fewer than `--min-runs`
runs are excluded from the ranking. The 🩺 dashboard tab renders the overall
trend as a sparkline and each region with a mini sparkline + pass rate, fed by
the same query — so long-term health is visible at a glance, not just the last
run's green/red state. `VERIFICATION_STATE.md` includes the same trend table.

## Daemon Integration

`deep-brain-kernel.py` JOBS table includes `verification_pass` (minute 56,
daily 07:56 UTC, direct/non-inference) so the scheduled brain verifies itself
once a day without touching CI. A red suite surfaces as job failure in
`--status` output. Each scheduled run appends one entry to the report ledger,
so the 🩺 sparkline grows one bar per day on its own — run
`backfill-history.sh` once on a fresh workspace to seed the trend immediately.

**Timeout note:** the daemon applies one global `--direct-timeout` (default
300s) to direct jobs. A full sweep runs every phase harness sequentially, so
the daily `verification_pass` can exceed that on slow machines and be killed
by the pidfd timeout. If `--status` shows `verification_pass` timing out,
raise `--direct-timeout` in `aibrain.service`'s `ExecStart` (or run the sweep
manually / in CI). The sweep itself is green on this host well under the
default.

## Self-Mod Integration (pre-deploy regression gate)

`core/self-mod/evaluate-proposal.sh` runs this sweep as its sandbox regression
gate: after a proposal is applied to a temp copy of the suite, it invokes
`scripts/run-declared-tests.sh --quiet` with an isolated `WORKSPACE` (so sandbox
state and signals never touch the live brain). Any declared test that fails →
the proposal is rejected before deploy (`regression_failed`). Suites without
the verification region (older installs, minimal test fixtures) fall back to
the phase1 harness, so existing evaluation behavior is preserved.

Alongside the sweep, evaluation also runs `deep-brain-kernel.py --check`
against the patched sandbox suite (`WORKSPACE` pointed at the sandbox suite and
`DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1`, since hermes presence is a host
concern, not a proposal-fixable one) — the daemon JOBS-table gate. A proposal
that breaks a job target (a script a job references that is missing or
truncated to empty — `--check` flags MISSING / EXISTS-BUT-EMPTY) is rejected
before deploy with `job_table_failed`, even when every declared test still
passes.

Baseline latency for the rollback thresholds is measured with the same sweep
(once per workspace), and a stored baseline measured with the old phase1
harness is re-measured automatically — so the latency rule compares like for
like instead of misreading the sweep's longer run as a regression.

The same sandbox gate runs on a **weekly cadence in CI**: the Verification
Gate workflow's `47 4 * * 1` schedule entry runs `scripts/deep-verify.sh`,
which drives `evaluate-proposal.sh` with a no-op probe proposal against HEAD.
The probe touches nothing tests cover and nothing the job table references, so
it is accepted if and only if every declared test is green AND the daemon job
table is intact on the default branch — with no PR open. Drift that would
block a real proposal reddens the weekly run instead of surfacing only when
the pipeline happens to fire.

## CI Integration

`.github/workflows/verification.yml` makes this sweep the suite's CI gate: on
every pull request, nightly on the default branch (catching drift between
PRs), and on demand from the Actions tab, GitHub Actions validates all
capability manifests (`core/schema/validate-manifest.sh --all`), validates the
daemon's JOBS table via `deep-brain-kernel.py --check` (minute uniqueness +
every direct job's script present, executable, and non-empty, with `WORKSPACE`
pointed at the checkout and `DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1` so the
runner's missing hermes isn't counted against the gate), runs the per-skill
unit suite (`tests/run_skill_unit_tests.sh`), then executes the
manifest-driven sweep (`scripts/run-declared-tests.sh --quiet`). A PR that
breaks any module's declared test — or declares a test path that doesn't
exist — fails the gate before merge. The same commands run locally as a single command:
`scripts/ci-gate.sh` replays the gate step-for-step with the exact CI
environment (`WORKSPACE` pointed at the checkout and
`DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1` for `--check`, plus an isolated scratch
workspace for the sweep, mirroring CI's `runner.temp`), so a green local gate
is a green CI run; no special CI wiring exists beyond the manifests themselves.

A second schedule entry (`47 4 * * 1`, weekly) adds the **deep verify**:
`scripts/deep-verify.sh` runs the self-mod proposal pipeline's own sandbox
gate — `core/self-mod/evaluate-proposal.sh` with a no-op probe proposal —
against HEAD, so the proposal pipeline is drift-checked on a cadence, not just
at PR time. The probe is accepted iff every declared test passes and the
daemon job table is intact; any drift rejects it and reddens the weekly run.

## Companion skills

- **vta-memory** — `tests_passed` → competence reward (drive boost).
- **acc-error-memory** — `test_failure` → logged error pattern.
- **amygdala-memory** — `test_failure` → frustration emotion.
- **thalamus-memory** — routes the signals through the attention gate.
