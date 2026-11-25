# Hermes Dependency Checklist

Tracks the "eclipse over replacement" metric from VISION.md Stage 2: each
item is either **INTERNALIZED** (no hermes needed), **OPTIONAL** (hermes
enhances but isn't required), or **REQUIRES HERMES** (data source or
integration point that needs the binary).

Last audited: 2026-08-24; revised 2026-11-25 for the current deployment.

> **2026-11-25 revision note:** the live deployment no longer runs under
> Hermes Agent at all. Since the Stage 3 cutover (2026-11-10) the suite
> runs as the agent Juno's own harness: agent reasoning for judgment work
> is Juno herself, reached through the suite's ask queue, keeper, and
> helm-drain rounds; transcripts come from the conversation wire, not
> from a Hermes session database. Rows below that described the Hermes
> integration are annotated where the current deployment supersedes them.
> "REQUIRES HERMES" is now **zero** in the live deployment — the two
> former cases are closed by replacement, not by new Hermes support.

## Spawn Jobs (core daemon dispatch)

| Item | Status | Evidence |
|---|---|---|
| Default spawn provider | ✅ INTERNALIZED | `SPAWN_PROVIDER=agentloop` is the default (Initiative 4) |
| agent-loop.sh tool-use loop | ✅ INTERNALIZED | `core/agent-loop/agent-loop.sh` — multi-turn reasoning with allowlisted tools |
| llm-call.sh local API | ✅ INTERNALIZED | `core/agent-loop/llm-call.sh` — direct OpenAI-compatible calls to local llama-server |
| spawn-provider.sh routing | ✅ INTERNALIZED | `core/spawn/spawn-provider.sh` — routes to agentloop/local/hermes based on `SPAWN_PROVIDER` |
| hermes chat fallback | ⚪ OPTIONAL | `generate-proposals-llm.sh` — hermes is one of three providers (local API preferred) |

## Self-Mod Pipeline

| Item | Status | Evidence |
|---|---|---|
| Proposal generation | ✅ INTERNALIZED | `generate-proposals-llm.sh` — local llama-server (OpenAI API) is the preferred path |
| Agent-loop proposals | ✅ INTERNALIZED | `--provider agentloop` routes through agent-loop.sh with tool-use context |
| Proposal ranking | ✅ INTERNALIZED | `rank-candidates.sh` — pure shell/python, no hermes dependency |
| Proposal evaluation | ✅ INTERNALIZED | `evaluate-proposal.sh` — sandbox + regression sweep, no hermes |
| Rollback | ✅ INTERNALIZED | `rollback.sh` — file restore + snapshot, no hermes |
| Graduation tracking | ✅ INTERNALIZED | `graduation-tracker.sh` — streak counter, no hermes |
| Autonomy tiers | ✅ INTERNALIZED | `check-tier.sh` — criteria evaluation, no hermes |

## Executive Function

| Item | Status | Evidence |
|---|---|---|
| Goal cycle | ✅ INTERNALIZED | `run-executive-cycle.sh` — reads PFC state, proposes goals |
| Reflection | ✅ INTERNALIZED | `isolated-reflect.sh` — reads cross-skill state |
| Proposal arbitration | ✅ INTERNALIZED | `arbitrate-proposals.sh` — goal-aligned scoring |
| Goal outcome recording | ✅ INTERNALIZED | `record-goal-outcome.sh` — VTA feedback loop |

## Transcripts

| Item | Status | Evidence |
|---|---|---|
| Session export | ✅ INTERNALIZED *(superseded 2026-11-25)* | Formerly: `export-transcripts.sh` read the Hermes session database (SQLite) — a genuine data-source dependency. In the current deployment the conversation wire (`core/gate/envelope.py`) ingresses every turn of the agent's own conversation, and the transcript bridge rewrites those payloads into the shapes the encoders read. No Hermes session database is involved. |
| Transcript preprocessing | ✅ INTERNALIZED | `preprocess.sh` — transforms exported JSONL, no hermes |

## Per-Skill Installation

| Item | Status | Evidence |
|---|---|---|
| Option B (daemon job table) | ✅ INTERNALIZED | The live JOBS table is `brain-daemon.sh`'s — 25 jobs, no hermes cron needed (the September kernel table had 30; see `BRAIN_DAEMON_SCHEDULE.md`) |
| Option A (hermes cron) | ⚪ LEGACY — not used | Per-skill `install.sh` scripts can call `hermes cron create` for Option A registration. The live deployment does not use this path; retained in the tree as the legacy registration route. |
| Skill registration | ⚪ OPTIONAL | `hermes skills list` shows registered skills — informational, not required for daemon operation; the live deployment's skills are read from the workspace directly |

## Workspace

| Item | Status | Evidence |
|---|---|---|
| `$HOME/.hermes/workspace` path | ✅ CONVENTION | Directory name only — no hermes binary required to read/write |
| State files (memory/*.json) | ✅ INTERNALIZED | All state files are plain JSON, read/written by shell scripts |

## Summary

| Category | Internalized | Optional | Requires Hermes |
|---|---|---|---|
| Spawn jobs | 4/5 | 1 | 0 |
| Self-mod pipeline | 7/7 | 0 | 0 |
| Executive function | 4/4 | 0 | 0 |
| Transcripts | 2/2 | 0 | 0 |
| Installation | 1/3 | 2 (incl. legacy Option A, unused) | 0 |
| Workspace | 2/2 | 0 | 0 |
| **Total** | **20/23** | **3** | **0** |

**Hermes is now optional for: all daemon operations, all self-mod pipeline
operations, all executive function, all workspace operations.**

**Hermes is still required for: nothing in the live deployment**
(2026-11-25). The two former requirements — transcript export (data
source) and Option A skill registration — were closed by replacement:
the conversation wire supplies transcripts, and the daemon job table is
the only registration the live deployment uses. The Hermes integration
code remains in the tree for the deployment shape it was built for; see
`HERMES_COMPATIBILITY.md`.
