---
name: social-memory
description: "Relationships and theory of mind for AI agents. Tracks specific people and other AI agents across conversations: who they are, trust and affinity, what we believe they want/feel, and what's owed or pending. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🫂"
    tags: ["memory", "social", "theory-of-mind", "ai-brain", "relationships"]
  openclaw:
    emoji: "🫂"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/social-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["python3", "jq"]
    tags: ["memory", "social", "theory-of-mind", "ai-brain", "relationships"]
---

# Social Memory 🫂

**Relationships and theory of mind: who they are, what's between you, what's pending.** Part of the AI Brain series.

Every relationship — human or AI agent — gets a `trust` and `affinity` score, a `beliefs` map (theory of mind: what we think they want/feel/believe right now), and a list of `openLoops` (things owed or pending, in either direction). This is what gives `heartbeat-memory`'s "reach out to a known AI agent" option real content instead of being generic.

## When to Use

Use this skill when:
- You interact with specific people or AI agents repeatedly and want persistent relationship state
- You need trust/affinity scoring, a theory-of-mind beliefs map, or pending open loops
- You want `heartbeat-memory`'s "reach out to a known agent" to have real context
- You're integrating with the AI Brain Suite and want social signals feeding Amygdala and VTA

Not for: generic contact lists, or relationship tracking you don't want persisting across sessions.

## Status: ✅ Live

## Quick Start

```bash
./install.sh --with-cron

./scripts/upsert-relationship.sh --id dyther --name "Dyther" --type human
./scripts/log-interaction.sh --id dyther --summary "Shipped the dashboard refactor together" --trust-delta 0.05
./scripts/update-belief.sh --id dyther --key "wants" --value "the brain suite to feel cohesive"
./scripts/open-loops.sh add --id dyther --description "Build the cerebellum skill next"
./scripts/get-relationship.sh --id dyther
```

## Scripts

| Script | Purpose |
|---|---|
| `upsert-relationship.sh` | Create or update a relationship's basic info (name/type/platform). |
| `log-interaction.sh` | Record an interaction; nudges trust/affinity by a small delta. |
| `update-belief.sh` | Theory of mind — record what you think they want/feel/believe. |
| `open-loops.sh` | `add` / `resolve` / `list` things owed or pending. |
| `list-relationships.sh` | Overview of everyone tracked. |
| `get-relationship.sh` | Full detail on one relationship. |
| `decay.sh` | Trust/affinity drift gently toward neutral after 7+ days of no contact. |
| `preprocess-mentions.sh` / `encode-pipeline.sh` | Scan transcripts for relationship-relevant signals (gratitude, promises, new mentions) and stage them for review. |
| `sync-state.sh` | Regenerates `SOCIAL_STATE.md` and the dashboard. |
| `generate-dashboard.sh` | Writes this skill's "🫂 Social" dashboard fragment. |
| `update-watermark.sh` | Advances the transcript watermark after encoding. |
| `log-event.sh` | Appends to the shared `brain-events.jsonl`. |

## Design notes

- **Trust and affinity are deliberately separate** from each other and move in small increments (±0.02–0.1 per interaction) — no single interaction should swing a relationship dramatically.
- **Decay only triggers after 7+ days of no contact**, and even then drifts only 5% of the distance to neutral per day — this models gradual distance, not punishment for being busy.
- **Beliefs are free-form**, not a fixed schema — `wants`, `feels`, `believes`, or any key that fits the relationship.

## State

`memory/social-state.json` — `relationships`, keyed by id: `name`, `type` (`human`/`ai_agent`), `platform`, `trust`, `affinity`, `beliefs`, `openLoops`, `notes`, contact timestamps.

## Companion skills

- **heartbeat-memory** — `social_interaction`/`social_media` options become meaningful with real relationship data behind them.
- **amygdala-memory** — emotional reactions to specific people could eventually cross-reference relationship affinity (not yet wired — would need careful scoping to avoid the cross-read pitfalls documented elsewhere in the suite).
