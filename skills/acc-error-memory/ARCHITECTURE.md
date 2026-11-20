# ACC Error Memory 🔴 Architecture

## Overview

Reactive error pattern tracking for AI agents. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/analyze-day.sh` | ACC: Analyze yesterday's transcript for errors Called by daily cron job |
| `scripts/calibrate-patterns.sh` | ACC Pattern Calibration — Self-improving regex system Samples exchanges, asks Juno, compares against regex coverage. |
| `scripts/encode-pipeline.sh` | ACC Encode Pipeline — Preprocess exchanges for error analysis Run this before the cron agent analyzes errors |
| `scripts/generate-dashboard.sh` | Generate unified Brain Dashboard (all 7 modules) All generate-dashboard.sh scripts in the suite are identical except for |
| `scripts/get-lessons.sh` | ACC: Retrieve lessons learned from resolved patterns Use this to check what worked before making decisions in similar contexts |
| `scripts/juno-screen.sh` | ACC Juno Screening — Juno confirms whether regex-filtered candidates are real errors (via juno-ask.sh) |
| `scripts/load-state.sh` | ACC: Load state at session start Shows current error patterns and lessons learned |
| `scripts/log-error.sh` | ACC: Log an error pattern |
| `scripts/log-event.sh` | Append a structured event to brain-events.jsonl Example: ./scripts/log-event.sh analysis errors_found=2 patterns_active=3 |
| `scripts/prefilter-exchanges.sh` | ACC Pre-filter — Cost optimization for error analysis pipeline Filters exchanges to only those containing error signals before Juno screening |
| `scripts/preprocess-errors.sh` | Preprocess session transcripts to extract user+assistant exchanges for ACC analysis Finds pairs where user might be correcting/frustrated with the assistant |
| `scripts/quick-check.sh` | ACC Quick Check — Lightweight real-time error signal detection Runs inline during conversation (no Juno ask, pure pattern matching) |
| `scripts/resolve-check.sh` | ACC: Check for patterns that should be resolved (30+ days without occurrence) Run as part of daily analysis |
| `scripts/sync-state-to-md.sh` | Deprecated wrapper; delegates to sync-state.sh sync-state.sh is the canonical implementation. |
| `scripts/sync-state.sh` | ACC: Generate ACC_STATE.md from acc-state.json Creates human-readable state for context injection |
| `scripts/update-watermark.sh` | Update ACC watermark after processing |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/acc-state.json`
- `memory/acc-watcher-watermark.json`
- `memory/brain-events.json`
- `memory/calibration-errors.json`
- `memory/calibration-state.json`
- `memory/conflict-state.json`
- `memory/emotional-state.json`
- `memory/habit-state.json`
- `memory/index.json`
- `memory/interoceptive-state.json`
- `memory/learned-patterns.json`
- `memory/pending-errors.json`
- `memory/reward-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `acc_error_analysis` | spawn | 4,12,20 | 18 |

## Prompts

- (none)

## Integration

Related packages (from `_meta.json`): (none declared in _meta.json).
