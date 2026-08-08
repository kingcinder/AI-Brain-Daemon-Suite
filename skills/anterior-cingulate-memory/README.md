# ⚡ Anterior Cingulate Memory

> Conflict detection and uncertainty monitoring for AI agents. Part of the [AI Brain series](https://github.com/ImpKind).

[![ClawdHub](https://img.shields.io/badge/ClawdHub-anterior--cingulate--memory-purple)](https://www.clawhub.ai/skills/anterior-cingulate-memory)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Give your AI agent a persistent sense of *something's off* — detecting information conflicts, flagging ambiguous intent, and tracking cognitive load across sessions.

## The Problem

Current AI agents:
- ✅ Process what they're told
- ❌ Don't notice when information contradicts itself
- ❌ Don't track cumulative uncertainty
- ❌ Respond confidently even when context is ambiguous
- ❌ Have no internal signal for "I should ask before proceeding"

**Without conflict detection, there's no inner alarm. Just execution — even when the instructions conflict.**

## The Solution

Track **conflict load** — a persistent uncertainty metric that rises when conflicts are detected and decays back to baseline when things resolve.

| Metric | What It Tracks |
|--------|----------------|
| **Conflict Load** | Overall uncertainty pressure (0.0–1.0) |
| **Active Conflicts** | Unresolved contradictions or ambiguities |
| **Attention Flags** | Topics that need extra care |
| **Uncertainty Zones** | Subject areas with insufficient confidence |

## Quick Start

```bash
# Install
clawdhub install anterior-cingulate-memory
cd ~/.hermes/workspace/skills/anterior-cingulate-memory
./install.sh --with-cron

# Check conflict state
./scripts/load-state.sh

# Log a conflict
./scripts/log-conflict.sh \
  --type instruction \
  --description "User said 'brief' then requested detailed analysis" \
  --resolution-hint "Ask for preferred format"

# Flag a topic for attention
./scripts/flag-attention.sh --add "database version" --reason "v1 vs v2 mentioned"

# Resolve a conflict
./scripts/resolve-conflict.sh --id "instruction_1749852000" \
  --resolution "User confirmed: detailed format preferred"
```

## How Conflict Load Works

```
CONFLICT DETECTED
      │
      ▼
┌─────────────────────────┐
│  log-conflict.sh        │──▶ load + (intensity × 0.15)
│  raises load            │
└───────────┬─────────────┘
            │
            ▼
   OVER TIME (CRON every 4h)
            │
            ▼
┌─────────────────────────┐
│  decay-load.sh          │──▶ load moves 20% toward baseline
│  drifts to baseline     │
└───────────┬─────────────┘
            │
            ▼
   CONFLICT RESOLVED
            │
            ▼
┌─────────────────────────┐
│  resolve-conflict.sh    │──▶ load - (intensity × 0.10)
│  lowers load            │
└─────────────────────────┘
```

## Load Levels

| Load | Status | Behavior |
|------|--------|----------|
| < 0.2 | 🟢 Clear | Proceed confidently |
| 0.2–0.4 | 🟡 Low | Note ambiguities |
| 0.4–0.6 | 🟠 Moderate | Verify key claims |
| 0.6–0.8 | 🔴 Elevated | Ask clarifying questions |
| > 0.8 | 🚨 Critical | Explicit caution required |

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Set up (run once) |
| `log-conflict.sh` | Log conflict, raise load |
| `resolve-conflict.sh` | Resolve conflict, lower load |
| `flag-attention.sh` | Add/remove attention flags |
| `load-state.sh` | Human-readable output |
| `decay-load.sh` | Load fades over time |
| `sync-state.sh` | Generate ACC_CONFLICT_STATE.md |
| `encode-pipeline.sh` | LLM-based conflict detection |
| `preprocess-exchanges.sh` | Extract exchanges for analysis |
| `update-watermark.sh` | Update processing watermark |
| `generate-dashboard.sh` | Generate unified brain dashboard |

## Conflict Types

| Type | When to Use |
|------|-------------|
| `factual` | Contradictory facts in conversation |
| `instruction` | Conflicting user instructions |
| `context` | Missing/unclear context |
| `uncertainty` | High uncertainty about a claim |
| `intent` | Ambiguous user intent |
| `knowledge_gap` | Insufficient knowledge to proceed |

## Auto-Injection

After install, `ACC_CONFLICT_STATE.md` is created in your workspace root and auto-injected into every session. No manual steps!

## Complement to acc-error-memory

These two skills cover different aspects of the ACC:

| Skill | Focus | Timing |
|-------|-------|--------|
| **anterior-cingulate-memory** | Proactive conflict detection | Real-time / in session |
| **acc-error-memory** | Reactive error pattern tracking | Post-correction learning |

**Which one logs a given signal?** If the agent notices the conflict,
ambiguity, or uncertainty *before* committing to an action or answer, it
belongs here (`anterior-cingulate-memory`). If it only exists because the
user corrected something the agent already said or did, it belongs in
`acc-error-memory` instead. The same underlying issue can legitimately show
up in both — this one records the flagged uncertainty in the moment,
`acc-error-memory` records the confirmed mistake afterward if the
uncertainty turned out to be founded — and that pairing is itself useful
calibration signal, not duplicate logging.

Install both for complete anterior cingulate coverage.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ **anterior-cingulate-memory** | Conflict detection and uncertainty monitoring | ✅ Live |
| [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## Philosophy

The anterior cingulate cortex fires when two competing responses are active simultaneously — when what you expected doesn't match what you got, when something feels *off* before you know why.

This skill gives AI agents that same metacognitive awareness: not just processing information, but *monitoring the processing itself*.

## Requirements

- Bash, jq, awk, bc, python3

## License

MIT

---

*Part of the AI Brain series. Built with ⚡ by [ImpKind](https://github.com/ImpKind)*
