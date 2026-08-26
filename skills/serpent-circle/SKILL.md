---
name: serpent-circle
description: "The repo-renovation meta-skillchain: runs the full repository overhaul ritual as one pipeline — brainstorm architecture + performance improvements (Python and every other language in the repo), write a plan, execute it, debug failures, clean up dead code and bloat, document everything, and commit. USE THIS SKILL whenever the user says 'tidy up the repo', 'tidy up', 'clean house', 'clean the repo', 'housekeeping', 'repo renovation', 'serpent circle', or asks to improve, optimize, refactor, or overhaul the whole repo end-to-end — even if they don't name this skill."
metadata:
  hermes:
    emoji: "🔁"
    tags: ["meta-skill", "orchestration", "refactoring", "performance", "cleanup", "git"]
    related_skills: ["improve-codebase-architecture", "python-performance-optimization", "writing-plans", "executing-plans", "systematic-debugging", "git-commit"]
  openclaw:
    emoji: "🔁"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/kingcider/AI-Brain-Daemon-Suite"
    requires:
      os: ["darwin", "linux"]
      bins: ["bash", "git", "jq", "python3"]
    tags: ["meta-skill", "orchestration", "refactoring", "performance"]
---

# Serpent Circle 🔁

The Serpent Circle is a **meta-skillchain**: it sequences six existing skills
into one repository-renovation pipeline, where **each stage's output is the
next stage's input** (real state passing, not just instructions).

It is the "tidy up the repo" / "clean house" skill.

## When to Use

Use the Serpent Circle whenever the user wants a whole-repo overhaul:

- "tidy up the repo", "tidy up", "clean house", "clean the repo", "housekeeping"
- "improve / optimize / refactor / overhaul the repo" (architecture or performance)
- "run the full improvement pipeline on this repo"

If the user asks for a single, narrow change (one bug, one file, one feature),
use the targeted skills directly instead — the Circle is for the whole pipeline.

## The Chain

| # | Stage | Skill(s) chained | Consumes | Produces |
|---|-------|------------------|----------|----------|
| 1 | **Brainstorm** | `improve-codebase-architecture` → `python-performance-optimization` → multi-language perf audit → **synthesize** | repo scan + `repo-inventory.txt` | `01-design/design.md` (+ architecture report) |
| 2 | **writing-plans** | `writing-plans` | design doc | `02-plan/plan.md` (step-by-step, review checkpoints) |
| 3 | **executing-plans** | `executing-plans` | plan | implemented + validated changes |
| 4 | **systematic-debugging** | `systematic-debugging` | failing tests / regressions | root-cause fixes + notes |
| 5 | **Cleanup** | (dead-code/bloat sweep) | working tree | dead code removed, repo tidied, docs updated |
| 6 | **Commit + push** | `git-commit` | tidy tree | conventional commit + gated push |

Stage 1 itself chains four moves:
- **1a** `improve-codebase-architecture` — scan for deepening opportunities.
- **1b** `python-performance-optimization` — profile Python hot paths (cProfile,
  memory profilers) and fix bottlenecks.
- **1c** Multi-language performance audit — JavaScript/TypeScript, C#, Rust,
  PowerShell, Shell, or any language found in the repo. Follow
  `references/perf-optimization.md` for per-language profilers and techniques.
- **1d** **Synthesize** — overhaul the brainstormed improvements into their
  most powerful, elegant, effective, and efficient forms before writing the
  design doc.

## State Passing (the contract)

Every stage reads its inputs from the chain workspace and writes its outputs
there. `scripts/serpent-circle.sh` scaffolds the workspace and produces the
inventory + plan:

```
.serpent-circle/
├── repo-inventory.txt   # git state, language histogram, bloat candidates (Stage 1 input)
├── state.json           # stage completion ledger (gates read this)
├── chain-plan.md        # the full 6-stage itinerary from --dry-run
├── 01-design/           # Stage 1 → Stage 2
├── 02-plan/             # Stage 2 → Stage 3
├── 03-execution/        # Stage 3 → Stage 4
├── 04-debug/            # Stage 4 → Stage 5
├── 05-cleanup/          # Stage 5 → Stage 6 (CHANGES.md)
└── 06-commit/           # Stage 6
```

**Rule:** a stage may only start after its input artifact exists (written by
the previous stage). Never skip a stage or improvise inputs — the chain's
value is that each stage conditions on real output from the one before it.

## Safety Gates

1. **`--dry-run` first.** Always start with `--dry-run`: it produces the full
   6-stage plan (with real inventory data) and writes nothing outside its own
   gitignored `.serpent-circle/` workspace — no tracked file is touched, no
   commit, no push. Execute only after the user reviews the plan.
2. **Commit is not push.** Stage 6 writes a conventional commit, then **stops
   and asks** before pushing. Push requires a git remote *and* explicit
   approval (`--push-ok` or a TTY confirmation). Never push implicitly.
3. **Never touch anything outside the repo.** The chain works on the working
   tree only.

## Quick Start

```bash
cd /path/to/repo
bash skills/serpent-circle/scripts/serpent-circle.sh --dry-run --repo "$PWD"
# → review .serpent-circle/chain-plan.md
bash skills/serpent-circle/scripts/serpent-circle.sh --inventory --repo "$PWD"
# → inspect the language + bloat scan
```

Then drive each stage per `references/chain-protocol.md`, running the
deterministic parts with `--stage N`.

See `references/chain-protocol.md` for the full per-stage protocol and
`references/perf-optimization.md` for the multi-language performance guide.
