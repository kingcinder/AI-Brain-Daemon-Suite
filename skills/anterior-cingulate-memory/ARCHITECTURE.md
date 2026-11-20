# Anterior Cingulate Memory ⚡ Architecture

## Overview

Conflict detection and uncertainty monitoring for AI agents. Tracks information conflicts, ambiguous intent, and cognitive load. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/decay-load.sh` | Scripts/decay-load.sh — Conflict load drifts toward baseline over time. Designed to run on cron every 4 hours. |
| `scripts/encode-pipeline.sh` | Scripts/encode-pipeline.sh — Juno-based conflict detection from conversation transcripts. |
| `scripts/flag-attention.sh` | Scripts/flag-attention.sh — Add or remove attention flags for risky topics |
| `scripts/generate-dashboard.sh` | Generate unified Brain Dashboard (all 7 modules) All generate-dashboard.sh scripts in the suite are identical except for |
| `scripts/get-state.sh` | Scripts/get-state.sh — Read raw conflict-state.json |
| `scripts/juno-ask.sh` | Ask Juno directly through the helm queue. |
| `scripts/load-state.sh` | Scripts/load-state.sh — Human-readable conflict state for session context |
| `scripts/log-conflict.sh` | Scripts/log-conflict.sh — Log a detected conflict and raise conflict load |
| `scripts/log-event.sh` | Append a structured event to brain-events.jsonl Example: ./scripts/log-event.sh encoding conflicts_found=2 load=0.45 |
| `scripts/preprocess-exchanges.sh` | Scripts/preprocess-exchanges.sh — Extract conversation exchanges from transcript for conflict analysis. Outputs a JSON array of {role, content} pairs. |
| `scripts/resolve-conflict.sh` | Scripts/resolve-conflict.sh — Mark a conflict resolved and lower conflict load |
| `scripts/safe-write.sh` | Flock-guarded wrapper for state-file read-modify-write cycles. |
| `scripts/sync-state.sh` | Scripts/sync-state.sh — Generate ACC_CONFLICT_STATE.md for session auto-injection |
| `scripts/update-watermark.sh` | Scripts/update-watermark.sh — Track the last processed transcript position for the encode-pipeline so we don't re-analyze the same exchanges. |

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
- `memory/reward-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `acc_conflict_encoding` | direct | 0,3,6,9,12,15,18,21 | 50 |
| `acc_conflict_decay` | direct | 0,4,8,12,16,20 | 16 |

## Prompts

- `prompts/detect-conflicts.md`

## Integration

Related packages (from `_meta.json`): `hippocampus`, `amygdala-memory`, `vta-memory`, `acc-error-memory`, `basal-ganglia-memory`, `insula-memory`.
