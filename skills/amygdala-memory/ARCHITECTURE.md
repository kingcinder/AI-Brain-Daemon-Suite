# Amygdala Memory 🎭 Architecture

## Overview

Emotional processing for AI agents. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/decay-emotion.sh` | Return emotional state toward baseline over time Run via cron (e.g., every 6 hours) to gradually normalize emotions |
| `scripts/encode-pipeline.sh` | Amygdala emotional encoding with Juno detection |
| `scripts/generate-dashboard.sh` | Generate unified Brain Dashboard (all 7 modules) All generate-dashboard.sh scripts in the suite are identical except for |
| `scripts/get-state.sh` | Read current emotional state |
| `scripts/load-emotion.sh` | Load emotional state for session context |
| `scripts/log-event.sh` | Log amygdala events to brain-events.jsonl Part of the amygdala-memory skill (ClawHub: @ImpKind/amygdala-memory) |
| `scripts/preprocess-emotions.sh` | Preprocess conversation for emotional content analysis Extracts signals that might have emotional significance |
| `scripts/sync-state.sh` | Generate AMYGDALA_STATE.md for auto-injection into OpenClaw sessions Generates FIRST-PERSON emotional state that can be inhabited, not just observed |
| `scripts/update-state.sh` | Also logs to emotion-log.jsonl for historical analysis Update emotional state ./update-state.sh --dimension <name> --delta <+/-value> |
| `scripts/update-watermark.sh` | Advance the watermark after processing emotional signals |
| `scripts/visualize.sh` | Terminal visualization of emotional state |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/acc-state.json`
- `memory/brain-events.json`
- `memory/conflict-state.json`
- `memory/emotional-log.json`
- `memory/emotional-signals.json`
- `memory/emotional-state.json`
- `memory/habit-state.json`
- `memory/index.json`
- `memory/interoceptive-state.json`
- `memory/pending-emotions.json`
- `memory/reward-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `amygdala_decay` | direct | 0,6,12,18 | 5 |
| `amygdala_encoding` | spawn | 0,3,6,9,12,15,18,21 | 10 |

## Prompts

- `prompts/encode-emotions.md`

## Integration

Related packages (from `_meta.json`): (none declared in _meta.json).
