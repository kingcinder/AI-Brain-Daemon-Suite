---
name: prefrontal-cortex-memory
description: "Executive function for AI agents: goal tracking, impulse control, and arbitration across the brain suite. Reads sibling skills' state to weigh candidate actions in context — the one skill in the suite designed to do that. Part of the AI Brain series."
metadata:
  openclaw:
    emoji: "🧭"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/prefrontal-cortex-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["python3", "jq"]
    tags: ["memory", "executive-function", "ai-brain", "decision-making"]
---

# Prefrontal Cortex 🧭

**Executive function: goals, impulse control, and cross-region arbitration.** Part of the AI Brain series.

Every other skill in the suite deliberately avoids reading its siblings' state — that decoupling is what makes the dashboard architecture and the rest of the suite maintainable (see the brain-suite review history for why cross-reads caused real bugs). Prefrontal cortex is the deliberate exception: synthesizing across brain regions to make one decision **is** executive function. Its `decide.sh` reads insula, VTA, amygdala, basal ganglia, and ACC's state — but every read is best-effort and optional, so it still works standalone with zero siblings installed.

## Status: ✅ Live

## What it does

- **`decide.sh`** — given a list of candidate options (each with an id/label/weight), scores them against current brain state and active goals/inhibitions, then picks one. This is what `heartbeat-memory` calls into for real arbitration instead of weighted-random choice.
- **Goals** — track active intentions with a priority. A goal whose description shares meaningful words with a candidate's label boosts that candidate's score.
- **Inhibitions** — impulse control. A pattern you don't want acted on (e.g. "interrupt mid-task") suppresses any matching candidate, scaled by strength.
- **Executive load** — a single scalar that tracks how much active deliberation is happening, decaying back toward baseline over time like the rest of the suite's decay scripts.

## How scoring works

For each candidate option, `decide.sh` starts from its given weight and adjusts it based on:
- High cognitive load / context saturation (from insula, if installed) → favors low-effort options
- Unresolved conflicts or error patterns (from ACC / acc-error, if installed) → favors consolidation/dreaming
- Active drive or seeking (from VTA, if installed) → favors project work
- Low energy or negative mood (from amygdala, if installed) → favors lighter options
- Active goals that share words with the option's label → direct boost, scaled by goal priority
- Active inhibitions that match the option → direct suppression, scaled by inhibition strength

The final pick is a weighted-random draw over the adjusted scores — not a hard argmax — so it doesn't get stuck always picking the same "best" option every time.

## Quick Start

```bash
./install.sh --with-cron

./scripts/goals.sh add --description "Ship the v2 dashboard" --priority 0.8
./scripts/inhibitions.sh add --pattern "interrupt mid-task" --reason "breaks flow" --strength 0.9

./scripts/decide.sh --context heartbeat --options '[
  {"id":"project_work","label":"Work on project","weight":1.0},
  {"id":"idle","label":"Stay quiet","weight":0.3}
]'
# {"chosen": "project_work", "reasoning": "active goal 'Ship the v2 dashboard' boosts project_work", ...}
```

## Scripts

| Script | Purpose |
|---|---|
| `decide.sh` | Score and pick among candidate options. Reads siblings (optional). |
| `goals.sh` | `add` / `list` / `complete` active goals. |
| `inhibitions.sh` | `add` / `list` / `remove` / `check` impulse-control patterns. |
| `decay-load.sh` | Eases executive load back toward baseline. |
| `get-state.sh` | Human-readable overview. |
| `sync-state.sh` | Regenerates `PFC_STATE.md` and the dashboard. |
| `generate-dashboard.sh` | Writes this skill's "🧭 Executive" dashboard fragment. |
| `log-event.sh` | Appends to the shared `brain-events.jsonl`. |

## State

`memory/pfc-state.json` — `executiveLoad`, `goals`, `inhibitions`, `decisionLog` (last 30, for auditing why a decision was made).

## Companion skills

- **heartbeat-memory** — calls `decide.sh` automatically if this skill is installed; otherwise falls back to weighted-random.
- Any skill can call `decide.sh` directly with its own candidate list — it's a general-purpose arbitration utility, not heartbeat-specific.
