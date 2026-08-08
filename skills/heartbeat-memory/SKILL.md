---
name: heartbeat-memory
description: "Autonomous initiative on a 30-minute timer. Decides whether to work on a project, check AI social media, reach out to a known agent, dream/consolidate recent learnings, or stay quiet — without waiting for the human to initiate. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "💓"
    tags: ["memory", "autonomy", "ai-brain", "scheduling", "circadian"]
  openclaw:
    emoji: "💓"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/heartbeat-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["python3", "jq"]
    tags: ["memory", "autonomy", "ai-brain", "scheduling", "circadian"]
---

# Heartbeat 💓

**A 30-minute timer that decides whether to act, and on what.** Part of the AI Brain series.

Every other skill in the brain suite is reactive — it only does anything when a person shows up, or in response to a narrow, fixed cron task (decay, encoding). Heartbeat is the first skill that represents the drive to act on its own initiative across genuinely open-ended options. It's the closest analog to a brainstem/reticular-activating-system trigger, with circadian rhythm folded in rather than built as a separate skill.

Heartbeat **decides**, it does not **execute** — it's a memory/decision skill, not an action skill. Each tick prints a directive ("here's what's eligible and what I'd pick") for the calling agent-turn to actually act on, then `log-action.sh` records what really happened.

## When to Use

Use this skill when:
- You want autonomous initiative on a timer instead of waiting for the human to initiate
- You want a decision about *what to do next* — work, social, dream, or stay quiet — respecting cooldowns and circadian phase
- You have `prefrontal-cortex-memory` installed and want real executive arbitration of candidates
- You're integrating with the AI Brain Suite and want `social-memory` context behind "reach out to a known agent"

Not for: executing the chosen action itself (Heartbeat only decides), or reactive responses to a person already present.

## Status: ✅ Live

## How it decides

1. Compute circadian phase from the current hour vs. configured wake/sleep hours: `waking`, `active`, `winding_down`, or `asleep`. During `asleep`, only `dreaming` is eligible — everything else is off the table.
2. Build the candidate list: each option in `options` that isn't on cooldown, with `project_work`/`own_projects` only eligible if there's a matching active project registered.
3. **If `prefrontal-cortex-memory` is installed**, hand the candidates to its `decide.sh` for real executive arbitration against current brain state (mood, drive, cognitive load, etc.).
4. **If not**, fall back to a weighted-random pick among eligible candidates — still respects cooldowns and circadian phase, just without cross-skill reasoning.
5. Records the choice. Does not mark it "done" until `log-action.sh` confirms.

This graceful degradation is intentional: Heartbeat works standalone, and gets smarter automatically if you also install Prefrontal Cortex.

## Quick Start

```bash
./install.sh --with-cron

# Register something it should consider working on
./scripts/projects.sh add --title "Finish the report" --type unfinished

# Manually trigger a tick (normally cron-driven, every 30 min)
./scripts/beat.sh

# After acting (or deciding not to), confirm what happened
./scripts/log-action.sh --action project_work --note "Drafted section 2"
```

## Scripts

| Script | Purpose |
|---|---|
| `beat.sh` | The tick. Decides what to consider doing right now; prints a directive. |
| `log-action.sh` | Confirms what actually happened after a beat (or that it was skipped). |
| `projects.sh` | `add` / `list` / `touch` / `complete` / `pause` for the project registry that feeds `project_work`/`own_projects`. |
| `set-circadian.sh` | Configure wake/sleep hours (UTC, 24h). |
| `get-state.sh` | Human-readable overview: beat count, last action, active projects, recent history. |
| `sync-state.sh` | Regenerates `HEARTBEAT_STATE.md` and the dashboard. |
| `generate-dashboard.sh` | Writes this skill's "💓 Pulse" dashboard fragment. |
| `log-event.sh` | Appends to the shared `brain-events.jsonl`. |

## Options (defaults)

| id | label | default weight | cooldown |
|---|---|---|---|
| `project_work` | Work on an unfinished project you asked for | 1.0 | none |
| `own_projects` | Work on a self-directed project | 0.8 | none |
| `social_media` | Check AI social media (e.g. Moltbook) | 0.6 | 2h |
| `social_interaction` | Reach out to / respond to a known AI agent | 0.6 | 1.5h |
| `dreaming` | Consolidate and integrate recent learnings | 0.5 | 4h |
| `idle` | Stay quiet, nothing urgent | 0.2 | none |

Weights and cooldowns live in `memory/heartbeat-state.json` and can be hand-edited.

## State

`memory/heartbeat-state.json` — `circadian`, `options` (weight/cooldown/lastDone per option), `projects` (registry), `actionHistory` (last 20), `beatCount`, `lastChosenAction`.

## Cron

Offset to `:07`/`:37` so it doesn't collide with the rest of the brain suite's encoding cron slots (`:00, :05, :10, :15, :20, :30, :45`).

## Companion skills

- **prefrontal-cortex-memory** — if installed, makes the actual choice instead of weighted-random.
- **social-memory** — gives `social_interaction` real known-agent context instead of being generic.
- **hippocampus-memory** — `dreaming` is meant to invoke hippocampus's own `consolidate.sh`/`reflect.sh` rather than duplicate that logic here.
