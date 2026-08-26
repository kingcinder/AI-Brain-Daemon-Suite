# Serpent Circle — Real-Run Policy Pass 2026-08-26

> **RELOCATED 2026-08-26:** the Serpent Circle skill no longer lives in this
> repo. It moved to the Freebuff global skills home:
> `~/.agents/skills/serpent-circle`. This
> document is a historical record of the standing-policy change.

The **standing-policy update** to the Serpent Circle meta-skillchain skill
(`skills/serpent-circle/`): the skill now **runs for real whenever invoked —
no dry-run-first step** — explicit whenever and wherever it is installed.

## The mandate (owner, verbatim intent)

> THIS IS NOT A DRY RUN — any time the skill is invoked from this point
> forward forever into the future, the meta skill is to be ran for real;
> that needs to be explicit WHENEVER AND WHEREEVER the skill is now ran.

## What changed

| File | Change |
|------|--------|
| `skills/serpent-circle/scripts/serpent-circle.sh` | No-mode invocation now defaults to `real_run()`: scaffolds the workspace, writes `state.json` with `"dry_run": false`, writes a REAL-RUN-labeled plan. `--dry-run` remains an explicit opt-in preview. `--run` is a documented no-op passthrough. Stage-6 push still mechanically gated on `--push-ok`. *(File relocated with the skill on 2026-08-26.)* |
| `skills/serpent-circle/SKILL.md` | New **STANDING POLICY** banner; Safety Gates rewritten (invocation = authorization; push rides with the real run; `--dry-run` opt-in only); blast-radius sentence (targets the repo where invoked, pushes only to that repo's configured remote); Quick Start now shows the no-flag real run. Loader-facing frontmatter description now says "commit and push" + real-run mandate. *(File relocated with the skill on 2026-08-26.)* |
| `skills/serpent-circle/references/chain-protocol.md` | Standing-policy note at top; Stage 1 prerequisite and Stage 6 push wording updated. *(File relocated with the skill on 2026-08-26.)* |
| `skills/serpent-circle/capability-manifest.json` | Capability `dry_run_planning` → `real_run_execution`. *(File relocated with the skill on 2026-08-26.)* |
| `tests/test_serpent_circle.sh` | New real-run assertions (no-mode default exits 0, REAL RUN banner, state `dry_run:false`, no commit created, git status clean); dry-run assertions retained as explicit-opt-in coverage. *(Test relocated with the skill on 2026-08-26.)* |

## Validation (Stage 4)

- **ci-gate:** all five steps green (41/41 declared verification tests).
- **Unit suite:** 52/52 skill unit tests.
- **Shellcheck:** 215/215 files clean at warning level.
- **Manifests:** all PASS, including the updated serpent-circle manifest.
- **Skill self-test:** OK; serpent-circle unit test 31/31.
- **Freebuff propagation:** `~/.agents/skills/serpent-circle` is a live symlink
  to `AI_BRAIN_SUITE_COMPLETE/skills/serpent-circle` — the policy change is
  live across Freebuff the moment it's committed.

## Cleanup (Stage 5)

- Removed 3 `__pycache__/*.pyc` build-junk files (untracked, gitignored).
- `legacy-IGNORE/` deliberately retained (documented rollback quarantine).
- This report + `BUGFIX_HISTORY.md` entry + `05-cleanup/CHANGES.md`.

## Commit + push (Stage 6)

Conventional commit(s), pushed to `origin/main` — invocation is the standing
authorization per the new policy.

## Relocation (same day)

Per the owner's direction, the skill was removed from this repo and installed
standalone at `~/.agents/skills/serpent-circle/` (the Freebuff global skills
home). The repo's unit suite
no longer includes `tests/test_serpent_circle.sh`; that test moved with the
skill. This file remains as a historical record.
