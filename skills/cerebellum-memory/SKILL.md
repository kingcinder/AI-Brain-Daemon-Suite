---
name: cerebellum-memory
description: "Procedural precision and smoothness — HOW something is executed, not WHAT to do. Tracks per-skill calibration via exponential moving average across repetitions. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🎚️"
    tags: ["memory", "procedural", "ai-brain", "calibration"]
  openclaw:
    emoji: "🎚️"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/cerebellum-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["python3", "jq"]
    tags: ["memory", "procedural", "ai-brain", "calibration"]
---

# Cerebellum 🎚️

**Procedural refinement: how well something gets executed, not what to do.** Part of the AI Brain series.

`basal-ganglia-memory` tracks *which* habit or procedure to run for a given cue. Cerebellum tracks *how well* the execution itself has been going — precision (closeness to the target outcome) and smoothness (consistency, not just average quality) for any named skill or task, refined over repetitions.

## When to Use

Use this skill when:
- You want to track how well you execute a named skill or task over repetitions (`log-execution.sh`)
- You want per-skill calibration and a global "how dialed-in is execution" number
- You want to notice drift or regression in execution quality before it becomes a habit

Not for: deciding *which* routine to run (that's `basal-ganglia-memory`), or one-shot quality judgments with no history.

## Status: ✅ Live

## Quick Start

```bash
./install.sh --with-cron

./scripts/log-execution.sh --skill "writing-bash-scripts" --quality 0.8 --note "clean, no syntax errors first try"
./scripts/log-execution.sh --skill "writing-bash-scripts" --quality 0.9
./scripts/get-calibration.sh
```

## How it scores

- **Precision** is an exponential moving average (α=0.3) of quality scores over time — recent reps matter more than old ones, but one bad rep doesn't erase a long track record.
- **Smoothness** rewards *consistency*, not high quality directly: it's the EMA of `1 - |quality - previous_precision|`. A skill that reliably performs at 0.6 has higher smoothness than one that swings between 0.3 and 0.9 even if their averages are similar — smoothness is about predictability, precision is about how good.
- **Global calibration** (`refine.sh`, cron'd every 8h) is the average precision across all tracked skills — a single number for "how dialed-in is execution right now, broadly."

## Scripts

| Script | Purpose |
|---|---|
| `log-execution.sh` | Record one rep: `--skill <name> --quality <0-1> [--note "..."]`. |
| `get-calibration.sh` | Overview, or `--skill <name>` for one skill's detail. |
| `refine.sh` | Recomputes global calibration from all tracked skills (cron'd). |
| `sync-state.sh` | Regenerates `CEREBELLUM_STATE.md` and the dashboard. |
| `generate-dashboard.sh` | Writes this skill's "🎚️ Precision" dashboard fragment. |
| `log-event.sh` | Appends to the shared `brain-events.jsonl`. |

## State

`memory/cerebellum-state.json` — `globalCalibration`, `skills` keyed by name: `precision`, `smoothness`, `reps`, `recentCorrections` (last 10 notes).

## Companion skills

- **basal-ganglia-memory** — the natural pairing: basal ganglia decides *what* habit to run, cerebellum tracks *how well* it's being run.
