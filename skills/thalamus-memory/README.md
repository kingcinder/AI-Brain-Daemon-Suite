# 🚦 Thalamus — Attention Gate & Signal Routing

Centralized attentional gating and signal routing for the AI Brain Suite. The thalamus receives signals from all brain skills and selectively amplifies or suppresses them based on current goals, executive load, and attentional priorities.

Part of the AI Brain series. Ported from the kernel lineage into the bash
suite on 2026-11-08 (Dyther decision #7); see CHANGELOG.md. The organ's own
SKILL.md and capability-manifest.json are the authoritative spec — this
README is the suite-convention summary.

## Scripts

- `scripts/gate.sh — score, filter, and dispatch pending signals`
- `scripts/decay.sh — release suppressed signals past their retry window`
- `scripts/neuromod-update.sh — recompute the global neuromodulator vector + workspace`
- `scripts/attention-filter.sh — the five-dimension relevance filter`
- `scripts/broadcast.sh / workspace-refresh.sh — global workspace composition`

## State

State lives under `$WORKSPACE/memory/` (default `~/.openclaw/workspace`),
shared with the rest of the suite. This organ follows the suite-wide
WORKSPACE / OPENCLAW_WORKSPACE env convention.
