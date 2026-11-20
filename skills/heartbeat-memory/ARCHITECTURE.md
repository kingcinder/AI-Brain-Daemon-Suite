# Heartbeat 💓 Architecture

## Overview

Autonomous initiative on a timer. Every 30 minutes, decides whether to work on a project, check AI social media, reach out to a known agent, dream/consolidate, or stay quiet — weighted by circadian phase and option cooldowns. Defers to prefrontal-cortex-memory for arbitration if installed. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/beat.sh` | The heartbeat tick. Decides what the agent should consider doing right now, given circadian phase, option cooldowns, and (if installed) |
| `scripts/dashboard-builder.sh` | Shared AI Brain Series dashboard assembler |
| `scripts/generate-dashboard.sh` | Write heartbeat's own dashboard fragment, then call the shared dashboard-builder.sh. Reads ONLY heartbeat's own state file. |
| `scripts/get-state.sh` | Human-readable heartbeat overview |
| `scripts/log-action.sh` | Confirm what actually happened after a beat |
| `scripts/log-event.sh` | Log heartbeat events to brain-events.jsonl |
| `scripts/projects.sh` | Manage the project registry heartbeat draws candidates from |
| `scripts/set-circadian.sh` | Configure wake/sleep hours (24h, local-to-UTC-already) |
| `scripts/sync-state.sh` | Generate HEARTBEAT_STATE.md for session injection |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/brain-events.json`
- `memory/heartbeat-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `heartbeat_beat` | direct | * | 7,37 |

## Prompts

- (none)

## Integration

Related packages (from `_meta.json`): `prefrontal-cortex-memory`, `hippocampus-memory`, `vta-memory`, `social-memory`.
