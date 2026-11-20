# Self-Mod Runner — Post-Deploy Monitor & Proposal Cycle

Daemon-facing entrypoints for the Phase 3 self-modification monitor loop. The pipeline lives under core/self-mod/ (Immutable Core for proposal targets); this skill invokes the monitor and the scheduled proposal cycle.

Part of the AI Brain series. Ported from the kernel lineage into the bash
suite on 2026-11-08 (Dyther decision #7); see CHANGELOG.md. The organ's own
SKILL.md and capability-manifest.json are the authoritative spec — this
README is the suite-convention summary.

## Scripts

- `scripts/monitor-tick.sh — invoke core/self-mod/monitor.sh`
- `scripts/proposal-cycle-tick.sh — weekly (Sunday, Pacific) proposal generation via core/self-mod/run-pipeline.sh`

## State

State lives under `$WORKSPACE/memory/` (default `~/.openclaw/workspace`),
shared with the rest of the suite. This organ follows the suite-wide
WORKSPACE / OPENCLAW_WORKSPACE env convention.
