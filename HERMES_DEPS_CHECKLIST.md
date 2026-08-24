# Hermes Dependency Checklist

Tracks the "eclipse over replacement" metric from VISION.md Stage 2: each
item is either **INTERNALIZED** (no hermes needed), **OPTIONAL** (hermes
enhances but isn't required), or **REQUIRES HERMES** (data source or
integration point that needs the binary).

Last audited: 2026-08-24

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
| Session export | 🔴 REQUIRES HERMES | `export-transcripts.sh` reads `~/.hermes/state.db` (SQLite). This is a data source dependency — hermes owns the session database. |
| Transcript preprocessing | ✅ INTERNALIZED | `preprocess.sh` — transforms exported JSONL, no hermes |

## Per-Skill Installation

| Item | Status | Evidence |
|---|---|---|
| Option B (daemon job table) | ✅ INTERNALIZED | `deep-brain-kernel.py` JOBS table — 30 jobs, no hermes cron needed |
| Option A (hermes cron) | 🔴 REQUIRES HERMES | Per-skill `install.sh` scripts call `hermes cron create` for Option A registration |
| Skill registration | ⚪ OPTIONAL | `hermes skills list` shows registered skills — informational, not required for daemon operation |

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
| Transcripts | 1/2 | 0 | 1 |
| Installation | 1/3 | 1 | 1 |
| Workspace | 2/2 | 0 | 0 |
| **Total** | **19/23** | **2** | **2** |

**Hermes is now optional for: all daemon operations, all self-mod pipeline
operations, all executive function, all workspace operations.**

**Hermes is still required for: transcript export (data source), Option A
skill registration (legacy path — Option B is the default).**
