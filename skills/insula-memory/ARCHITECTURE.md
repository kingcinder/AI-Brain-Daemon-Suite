# Insula — Interoceptive Awareness 🌡️ Architecture

## Overview

The felt sense beneath emotion. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/decay-sense.sh` | Return channels toward baseline (12% per run, every 4h) |
| `scripts/encode-pipeline.sh` | Full interoceptive encoding pipeline 1. Preprocess transcripts for signals 2. Apply rule-based signals directly (no Juno ask needed for insula) |
| `scripts/generate-dashboard.sh` | Generate unified Brain Dashboard (all 7 modules) All generate-dashboard.sh scripts in the suite are identical except for |
| `scripts/get-state.sh` | Print current interoceptive state |
| `scripts/load-sense.sh` | Human-readable state for session context injection |
| `scripts/log-event.sh` | Append structured event to brain-events.jsonl |
| `scripts/preprocess-sense.sh` | Extract interoceptive signals from session transcripts Scans for friction, resonance, depletion, flow patterns since last watermark. |
| `scripts/sync-state.sh` | Generate INSULA_STATE.md from interoceptive-state.json |
| `scripts/update-state.sh` | Log a gut signal or set a channel directly ./scripts/update-state.sh --signal <name> [--intensity <0.0-1.0>] [--source <text>] |
| `scripts/update-watermark.sh` | Advance lastProcessedSignal watermark |
| `scripts/visualize.sh` | Terminal ASCII visualization of interoceptive state |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/acc-state.json`
- `memory/brain-events.json`
- `memory/conflict-state.json`
- `memory/emotional-state.json`
- `memory/habit-state.json`
- `memory/index.json`
- `memory/interoceptive-state.json`
- `memory/pending-sense.json`
- `memory/reward-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `insula_encoding` | direct | 0,3,6,9,12,15,18,21 | 40 |
| `insula_decay` | direct | 0,4,8,12,16,20 | 14 |

## Prompts

- `prompts/encode-sense.md`

## Integration

Related packages (from `_meta.json`): (none declared in _meta.json).
