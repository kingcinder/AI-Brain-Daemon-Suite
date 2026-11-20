# Social Memory 🫂 Architecture

## Overview

Relationships and theory of mind for AI agents. Tracks specific people and other AI agents across conversations: who they are, trust and affinity, what we believe they want/feel, and what's owed or pending. Part of the AI Brain series.

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
| `scripts/decay.sh` | Trust/affinity drift gently toward neutral (0.5) without contact. Models distance, not punishment: only relationships untouched for 7+ days move. |
| `scripts/encode-pipeline.sh` | Social signal encoding |
| `scripts/generate-dashboard.sh` | Write social-memory's own dashboard fragment, then call the shared dashboard-builder.sh. Reads ONLY social-memory's own state. |
| `scripts/get-relationship.sh` | Read one relationship record from memory/social-state.json (series get-* utility; the source script carries no header description) |
| `scripts/list-relationships.sh` | List the relationship records in memory/social-state.json (the source script carries no header description) |
| `scripts/log-event.sh` | Append a timestamped event record to the shared memory/brain-events.json log (series-shared utility; the source script carries no header description) |
| `scripts/log-interaction.sh` | Record an interaction with a relationship |
| `scripts/open-loops.sh` | Track what's owed or pending with someone add --id <id> --description "..." resolve --id <id> --loop-id <loop_id> |
| `scripts/preprocess-mentions.sh` | Scan transcripts for relationship-relevant signals: new people/agents mentioned, trust/affinity-relevant moments, things promised. |
| `scripts/sync-state.sh` | Render memory/social-state.json into the workspace SOCIAL_STATE.md inject file (the source script carries no header description) |
| `scripts/update-belief.sh` | Theory of mind: record what we think this person/agent believes, wants, or feels. Free-form key/value. |
| `scripts/update-watermark.sh` | Advance watermark after processing social signals |
| `scripts/upsert-relationship.sh` | Create or update a relationship's basic info |

## Data & State

State lives in the shared workspace (`$WORKSPACE/memory/`, initialized by
`install.sh`). State files referenced in this organ's scripts — its own
state plus any sibling state it reads for cross-organ signals:

- `memory/brain-events.json`
- `memory/social-signals.json`
- `memory/social-state.json`
- `memory/social-watermark.json`

## Scheduling (brain-daemon.sh job table)

| Job | Kind | Hours | Minutes |
|---|---|---|---|
| `social_decay` | direct | 0 | 24 |
| `social_encoding` | spawn | 0,3,6,9,12,15,18,21 | 52 |

## Prompts

- `prompts/encode-social.md`

## Integration

Related packages (from `_meta.json`): `heartbeat-memory`, `amygdala-memory`, `hippocampus-memory`.
