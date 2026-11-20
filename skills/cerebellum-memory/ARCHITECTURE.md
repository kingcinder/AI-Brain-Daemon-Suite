# Cerebellum 🎚️ Architecture

## Overview

Procedural precision and smoothness — HOW something is executed, not WHAT to do (that's basal-ganglia-memory's job). Tracks per-skill precision (closeness to target outcome) and smoothness (consistency over time) via exponential moving average. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/dashboard-builder.sh` | Shared AI Brain Series dashboard assembler |
| `scripts/generate-dashboard.sh` | Write cerebellum's own dashboard fragment, then call the shared dashboard-builder.sh. Reads ONLY cerebellum's own state file. |
| `scripts/get-calibration.sh` | Read calibration values from memory/cerebellum-state.json (per-skill via --skill, optional --json; purpose from the script's usage line — no header description in source) |
| `scripts/log-event.sh` | Append a timestamped event record to the shared memory/brain-events.json log (series-shared utility; the source script carries no header description) |
| `scripts/log-execution.sh` | Record one rep of executing a skill, refining its precision (how close to the target outcome) and smoothness (how |
| `scripts/refine.sh` | Recompute global calibration from tracked skills (periodic, cron) |
| `scripts/sync-state.sh` | Render memory/cerebellum-state.json into the workspace CEREBELLUM_STATE.md inject file (the source script carries no header description) |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/brain-events.json`
- `memory/cerebellum-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `cerebellum_refine` | direct | 0,8,16 | 26 |

## Prompts

- (none)

## Integration

Related packages (from `_meta.json`): `basal-ganglia-memory`.
