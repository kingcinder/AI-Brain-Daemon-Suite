# Prefrontal Cortex 🧭 Architecture

## Overview

Executive function: goal tracking, impulse control, and arbitration across the brain suite. decide.sh reads sibling skills' state (insula, VTA, amygdala, basal ganglia, ACC) to weigh candidate actions in context, and is the decision-maker heartbeat-memory defers to when installed. Part of the AI Brain series.

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
| `scripts/decay-load.sh` | Executive load eases back toward baseline over time |
| `scripts/decide.sh` | Executive arbitration among candidate options. |
| `scripts/generate-dashboard.sh` | Write PFC's own dashboard fragment, then call the shared dashboard-builder.sh. Reads ONLY PFC's own state file (its decide.sh |
| `scripts/get-state.sh` | Read memory/pfc-state.json for inspection (series get-* utility; the source script carries no header description) |
| `scripts/goals.sh` | Manage executive goals add --description "..." [--priority 0.0-1.0] [--deadline "..."] list [--status active|complete] |
| `scripts/inhibitions.sh` | Manage impulse-control patterns (things to resist) add --pattern "..." --reason "..." [--strength 0.0-1.0] |
| `scripts/juno-ask.sh` | Ask Juno directly through the helm queue. |
| `scripts/log-event.sh` | Append a timestamped event record to the shared memory/brain-events.json log (series-shared utility; the source script carries no header description) |
| `scripts/safe-write.sh` | Flock-guarded wrapper for state-file read-modify-write cycles. |
| `scripts/semantic-match.sh` | Ask Juno which goals/inhibitions are actually relevant to which candidate options, replacing the old bash/jq word-overlap |
| `scripts/sync-state.sh` | Render memory/pfc-state.json into the workspace PFC_STATE.md inject file (the source script carries no header description) |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/acc-state.json`
- `memory/brain-events.json`
- `memory/cerebellum-state.json`
- `memory/conflict-state.json`
- `memory/emotional-state.json`
- `memory/habit-state.json`
- `memory/interoceptive-state.json`
- `memory/pfc-state.json`
- `memory/reward-state.json`
- `memory/social-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `pfc_decay` | direct | 0,6,12,18 | 22 |

## Prompts

- (none)

## Integration

Related packages (from `_meta.json`): `heartbeat-memory`, `insula-memory`, `vta-memory`, `amygdala-memory`, `basal-ganglia-memory`, `anterior-cingulate-memory`, `acc-error-memory`.
