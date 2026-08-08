# ⭐ VTA Memory

> Reward and motivation system for AI agents. Part of the [AI Brain series](https://github.com/ImpKind).

[![ClawdHub](https://img.shields.io/badge/ClawdHub-vta--memory-purple)](https://www.clawhub.ai/skills/vta-memory)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Give your AI agent genuine *wanting* — not just doing things when asked, but having drive, seeking rewards, and looking forward to things.

## The Problem

Current AI agents:
- ✅ Do what they're asked
- ❌ Don't *want* anything
- ❌ Have no internal motivation
- ❌ Don't feel satisfaction from accomplishment

**Without a reward system, there's no desire. Just execution.**

## The Solution

Track motivation through:
- **Drive** — overall motivation level (0-1)
- **Rewards** — logged accomplishments that boost drive
- **Seeking** — what I actively want more of
- **Anticipation** — what I'm looking forward to

## Quick Start

```bash
# Install
clawdhub install vta-memory
cd ~/.hermes/workspace/skills/vta-memory
./install.sh --with-cron

# Check motivation
./scripts/load-motivation.sh

# Log a reward
./scripts/log-reward.sh --type accomplishment --source "shipped feature" --intensity 0.8

# Add anticipation
./scripts/anticipate.sh --add "morning conversation"
```

## How It Works

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Do        │────▶│   Get       │────▶│   Drive     │
│   Thing     │     │   Reward    │     │   Goes UP   │
└─────────────┘     └─────────────┘     └──────┬──────┘
      ▲                                        │
      │                                        │
      └────────────────────────────────────────┘
           High drive = want to do more
```

### Drive Mechanics

| Event | Effect |
|-------|--------|
| Log reward | +intensity × 0.2 |
| Add anticipation | +0.05 |
| Decay (8h) | Move 15% toward baseline |

### Drive Levels

| Level | Description | Behavior |
|-------|-------------|----------|
| > 0.8 | Highly motivated | Eager, proactive |
| 0.6-0.8 | Motivated | Ready to work |
| 0.4-0.6 | Moderate | Can engage |
| < 0.4 | Low | Need a win |

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Set up (run once) |
| `log-reward.sh` | Log reward, boost drive |
| `anticipate.sh` | Add things to look forward to |
| `seek.sh` | Add things we're seeking |
| `load-motivation.sh` | Human-readable output |
| `decay-drive.sh` | Drive fades over time |
| `sync-motivation.sh` | Generate VTA_STATE.md |
| `resolve-anticipation.sh` | Mark anticipation as fulfilled |
| `preprocess-rewards.sh` | Extract reward signals from transcript |
| `update-watermark.sh` | Update processing watermark |
| `generate-dashboard.sh` | Generate unified brain dashboard |

## Brain Dashboard

Visual dashboard showing all installed brain skills.

**Generated automatically on install and cron runs.**

Access at: `~/.hermes/workspace/brain-dashboard.html`

```bash
# Generate manually
./scripts/generate-dashboard.sh

# Open (macOS)
open ~/.hermes/workspace/brain-dashboard.html

# Open (Linux)  
xdg-open ~/.hermes/workspace/brain-dashboard.html
```

Shows tabs for all installed brain skills: 🧠 Memory, 🎭 Emotions, ⭐ Drive, 🎯 Habits, 🌡️ Sense, ⚡ Oversight — with install prompts for missing modules.

## Reward Types

| Type | When to Use |
|------|-------------|
| `accomplishment` | Completed task, shipped something |
| `social` | User appreciation, positive feedback |
| `curiosity` | Learned something new |
| `connection` | Deep conversation, bonding |
| `creative` | Made something |
| `competence` | Solved hard problem |

## Auto-Injection

After install, `VTA_STATE.md` is created in your workspace root and auto-injected into every session. No manual steps!

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| ⭐ **vta-memory** | Reward and motivation | ✅ Live |
| [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## Philosophy

The VTA produces dopamine — not the "pleasure chemical" but the "wanting chemical."

**Wanting** (motivation) ≠ **Liking** (pleasure)

This skill implements *wanting* — the drive that makes action happen. Without it, why would an AI do anything beyond what it's explicitly asked?

## Requirements

- Bash, jq, awk, bc

## License

MIT

---

*Part of the AI Brain series. Built with ⭐ by [ImpKind](https://github.com/ImpKind)*
