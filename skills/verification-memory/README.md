# 🩺 Verification — the Brain's Proprioception

A verification region that runs every other module's declared tests from their capability manifests, reports a green/red felt state onto the signal bus, and feeds failures into the error/emotion systems.

Part of the AI Brain series. Ported from the kernel lineage into the bash
suite on 2026-11-08 (Dyther decision #7); see CHANGELOG.md. The organ's own
SKILL.md and capability-manifest.json are the authoritative spec — this
README is the suite-convention summary.

## Scripts

- `scripts/run-declared-tests.sh — manifest-driven discovery + execution of declared tests`
- `scripts/run-module-tests.sh — run one module's declared tests`
- `scripts/query-history.sh / backfill-history.sh — verification history`
- `scripts/sync-state.sh — publish verification state`

## State

State lives under `$WORKSPACE/memory/` (default `~/.openclaw/workspace`),
shared with the rest of the suite. This organ follows the suite-wide
WORKSPACE / OPENCLAW_WORKSPACE env convention.
