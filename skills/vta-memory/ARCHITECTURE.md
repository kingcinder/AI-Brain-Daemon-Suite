# VTA Memory ⭐ Architecture

## Overview

Reward and motivation for AI agents. Part of the AI Brain series.

Part of the AI Brain Daemon Suite (legacy bash generation). This document
was created during the 2026-11-08 suite completeness audit from the package's
own files — component purposes are taken from each script's own header,
state files from the scripts' actual references, and scheduling from
`brain-daemon.sh`'s job table.

---

## System Components

| Component | Purpose |
|---|---|
| `scripts/anticipate.sh` | Add or remove things to look forward to ./anticipate.sh --remove "morning conversation" ./anticipate.sh --list |
| `scripts/decay-drive.sh` | Drive decays without rewards over time |
| `scripts/encode-pipeline.sh` | VTA reward encoding with Juno detection |
| `scripts/generate-dashboard.sh` | Generate unified Brain Dashboard (all 7 modules) All generate-dashboard.sh scripts in the suite are identical except for |
| `scripts/get-drive.sh` | Read current motivation/drive state |
| `scripts/load-motivation.sh` | Load motivation state for session context |
| `scripts/log-event.sh` | Log VTA events to brain-events.jsonl Part of the vta-memory skill (ClawHub: @ImpKind/vta-memory) |
| `scripts/log-reward.sh` | Log a reward event and boost drive |
| `scripts/preprocess-rewards.sh` | Preprocess conversation for reward/accomplishment signals Extracts signals about wins, completions, social rewards, etc. |
| `scripts/resolve-anticipation.sh` | Mark an anticipation as resolved (it happened!) |
| `scripts/seek.sh` | Add or remove things we're actively seeking/wanting ./seek.sh --remove "creative work" ./seek.sh --list |
| `scripts/sync-motivation.sh` | Generate VTA_STATE.md for auto-injection First-person framing for inhabited experience |
| `scripts/update-watermark.sh` | Update the lastProcessedSignal after encoding |

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
- `memory/pending-rewards.json`
- `memory/reward-log.json`
- `memory/reward-signals.json`
- `memory/reward-state.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `vta_decay` | direct | 4,12,20 | 8 |
| `vta_encoding` | spawn | 0,3,6,9,12,15,18,21 | 20 |

## Prompts

- `prompts/encode-rewards.md`

## Integration

Related packages (from `_meta.json`): (none declared in _meta.json).
