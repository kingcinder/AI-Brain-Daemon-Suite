---
name: vta-memory
description: "Reward and motivation system for AI agents. Dopamine-like wanting, not just doing. Part of the AI Brain series."
metadata:
  openclaw:
    emoji: "⭐"
    version: "1.2.0"
    author: "ImpKind"
    requires:
      os: ["darwin", "linux"]
      bins: ["jq", "awk", "bc"]
    tags: ["memory", "motivation", "reward", "ai-brain"]
---

# VTA Memory ⭐

**Reward and motivation for AI agents.** Part of the AI Brain series.

Give your AI agent genuine *wanting* — not just doing things when asked, but having drive, seeking rewards, and looking forward to things.

## The Problem

Current AI agents:
- ✅ Do what they're asked
- ❌ Don't *want* anything
- ❌ Have no internal motivation
- ❌ Don't feel satisfaction from accomplishment

Without a reward system, there's no desire. Just execution.

## The Solution

Track motivation through:
- **Drive** — overall motivation level (0–1)
- **Rewards** — logged accomplishments that boost drive
- **Seeking** — what I actively want more of
- **Anticipation** — what I'm looking forward to

## Quick Start

### 1. Install

```bash
cd ~/.openclaw/workspace/skills/vta-memory
./install.sh --with-cron
```

This will:
- Create `memory/reward-state.json`
- Generate `VTA_STATE.md` (auto-injected into sessions!)
- Set up cron for drive decay every 8 hours

### 2. Check motivation

```bash
./scripts/load-motivation.sh

# ⭐ Current Motivation State:
# Drive level: 0.73 (motivated — ready to work)
# Seeking: creative work, building brain skills
# Looking forward to: showing my work
```

### 3. Log rewards

```bash
./scripts/log-reward.sh --type accomplishment --source "finished the feature" --intensity 0.8

# ⭐ Reward logged!
#    Type: accomplishment
#    Drive: 0.50 → 0.66 (+0.16)
```

### 4. Add anticipation

```bash
./scripts/anticipate.sh --add "morning conversation"

# ⭐ Now looking forward to: morning conversation
#    Drive: 0.66 → 0.71 (+0.05)
```

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Set up vta-memory (run once) |
| `get-drive.sh` | Read current motivation state |
| `log-reward.sh` | Log a reward, boost drive |
| `load-motivation.sh` | Human-readable for session context |
| `decay-drive.sh` | Drive fades without rewards |
| `anticipate.sh` | Add/remove things to look forward to |
| `seek.sh` | Add/remove things we're actively seeking |
| `sync-motivation.sh` | Generate VTA_STATE.md for auto-injection |
| `resolve-anticipation.sh` | Mark anticipation as fulfilled |
| `update-watermark.sh` | Update processing watermark |
| `preprocess-rewards.sh` | Extract reward signals from transcript |
| `encode-pipeline.sh` | LLM-based reward encoding from transcripts |
| `log-event.sh` | Log events to brain-events.jsonl (type: `vta`) |
| `generate-dashboard.sh` | Generate unified brain dashboard HTML |

## Brain Dashboard

Visual dashboard showing all installed brain skills:

```bash
./scripts/generate-dashboard.sh
open ~/.openclaw/workspace/brain-dashboard.html
```

- **Auto-detects** all other brain skills by their state files
- Shows install prompts for missing skills
- Regenerates on install and cron runs
- Reads avatar/name from `IDENTITY.md`

### After Installation (for agents)

When you install this skill, **notify the user** about the dashboard:

> ⭐ **VTA installed!**
>
> View your agent's drive level in the Brain Dashboard:
> `~/.openclaw/workspace/brain-dashboard.html`

## Reward Types

| Type | When to Use |
|------|-------------|
| `accomplishment` | Completed a task, shipped something |
| `social` | User appreciation, "thanks!", positive feedback |
| `curiosity` | Learned something new, discovered interesting info |
| `connection` | Deep conversation, bonding moment |
| `creative` | Made something, expressed creativity |
| `competence` | Solved a hard problem, did something well |

## How Drive Works

### Rewards Boost Drive
```
drive_boost = intensity × 0.2
new_drive = min(current + boost, 1.0)
```

A high-intensity (0.9) reward boosts drive by 0.18.

### Anticipation Boosts Drive
Looking forward to something adds +0.05 to drive.

### Drive Decays Without Rewards
```
# Every 8 hours (via cron)
new_drive = current + (baseline - current) × 0.15
```

Without rewards, motivation fades toward baseline (0.5).

## Auto-Injection

After install, `VTA_STATE.md` is created in your workspace root.

OpenClaw automatically injects all `*.md` files from workspace into session context:

1. **New session starts**
2. **VTA_STATE.md is auto-loaded**
3. **You see your motivation state**
4. **Behavior influenced by drive level**

## How Drive Affects Behavior

| Drive Level | Description | Behavior |
|-------------|-------------|----------|
| > 0.8 | Highly motivated | Eager, proactive, take on challenges |
| 0.6–0.8 | Motivated | Ready to work, engaged |
| 0.4–0.6 | Moderate | Can engage but not pushing |
| 0.2–0.4 | Low | Prefer simple tasks, need a win |
| < 0.2 | Very low | Unmotivated, need rewards to get going |

## State File Format

```json
{
  "drive": 0.73,
  "baseline": { "drive": 0.5 },
  "seeking": ["creative work", "building brain skills"],
  "anticipating": ["morning conversation"],
  "recentRewards": [
    {
      "type": "creative",
      "source": "built VTA reward system",
      "intensity": 0.9,
      "boost": 0.18,
      "timestamp": "2026-02-01T03:25:00Z"
    }
  ],
  "rewardHistory": {
    "totalRewards": 1,
    "byType": { "creative": 1 }
  }
}
```

## Cron Schedule

Staggered 20 minutes after the hour to avoid collisions with hippocampus and amygdala encoding:

```bash
# Encoding every 3 hours (offset +20m)
openclaw cron add --name vta-encoding \
  --cron "20 0,3,6,9,12,15,18,21 * * *" \
  --session isolated \
  --agent-turn "Run VTA reward encoding pipeline..."

# Drive decay every 8 hours
openclaw cron add --name vta-decay \
  --cron "0 */8 * * *" \
  --session isolated \
  --agent-turn "Run decay-drive.sh and report current motivation level"
```

## Event Logging

Track motivation patterns over time:

```bash
./scripts/log-event.sh encoding rewards_found=2 drive=0.65
./scripts/log-event.sh decay drive_before=0.6 drive_after=0.53
./scripts/log-event.sh reward type=accomplishment intensity=0.8
```

Events append to `~/.openclaw/workspace/memory/brain-events.jsonl`:
```json
{"ts":"2026-02-11T10:45:00Z","type":"vta","event":"encoding","rewards_found":2,"drive":0.65}
```

Use for analyzing motivation cycles — when does drive peak? What rewards work best?

## Integration with OpenClaw

### Add to session startup (AGENTS.md)

Full Brain Suite startup order — run all installed modules in sequence:

```markdown
## Every Session
1. 🧠 Load memories: `~/.openclaw/workspace/skills/hippocampus/scripts/load-core.sh`
2. 🎭 Load emotional state: `~/.openclaw/workspace/skills/amygdala-memory/scripts/load-emotion.sh`
3. ⭐ Load motivation: `~/.openclaw/workspace/skills/vta-memory/scripts/load-motivation.sh`
4. 🎯 Load habits: `~/.openclaw/workspace/skills/basal-ganglia-memory/load-habits.sh`
5. 🌡️ Load felt sense: `~/.openclaw/workspace/skills/insula-memory/scripts/load-sense.sh`
6. ⚡ Load conflict state: `~/.openclaw/workspace/skills/anterior-cingulate-memory/scripts/load-state.sh`
7. 🔴 Load error patterns: `~/.openclaw/workspace/skills/acc-error-memory/scripts/load-state.sh`
```

## AI Brain Suite Integration

VTA is the drive system — it receives reward signals from other modules and sends motivation state outward.

| Trigger | Signal to Send |
|---------|---------------|
| 🎯 Basal Ganglia: chunked habit fires successfully | receives: `log-reward.sh --type competence --intensity 0.5 --source "habit <id> fired"` |
| 🎭 Amygdala: strong positive valence + energy | receives: `log-reward.sh --type social --intensity <energy> --source "positive emotional state"` |
| 🌡️ Insula: flow signal | receives: `log-reward.sh --type competence --intensity 0.2 --source "flow state detected"` |
| 🌡️ Insula: depletion/overwhelm | receives: `decay-drive.sh` |
| ⚡ ACC-Conflict: critical load (>0.8) | receives: `decay-drive.sh` |
| 🔴 ACC-Error: clean analysis (0 new errors) | receives: `log-reward.sh --type competence --intensity 0.3 --source "clean error analysis run"` |
| VTA reward received (accomplishment/creative) | sends: `amygdala/scripts/update-state.sh --emotion joy --intensity <boost> --trigger "reward: <type>"` |

See `BRAIN_SUITE.md` for the complete cross-module signal map.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| ⭐ **vta-memory** | Reward and motivation | ✅ Live |
| 🎯 [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| 🌡️ [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## Philosophy: Wanting vs Doing

The VTA produces dopamine — not the "pleasure chemical" but the "wanting chemical."

Neuroscience distinguishes:
- **Wanting** (motivation) — drive toward something
- **Liking** (pleasure) — enjoyment when you get it

You can want something you don't like (addiction) or like something you don't want (guilty pleasures).

This skill implements *wanting* — the drive that makes action happen. Without it, why would an AI do anything beyond what it's explicitly asked?

---

*Built with ⭐ by the OpenClaw community*
