---
name: amygdala-memory
description: "Emotional processing layer for AI agents. Persistent emotional states that influence behavior and responses. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🎭"
    tags: ["memory", "emotions", "ai-brain"]
  openclaw:
    emoji: "🎭"
    version: "1.7.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/amygdala-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["jq", "awk"]
    tags: ["memory", "emotions", "ai-brain"]
---

# Amygdala Memory 🎭

**Emotional processing for AI agents.** Part of the AI Brain series.

Give your AI agent persistent emotional states that carry across sessions. Not just performing emotions — *having* them.

## When to Use

Use this skill when:
- You want persistent emotional state that survives session boundaries and colors future responses
- Something meaningful happened and you want to record how it made you feel (via `update-state.sh`)
- You want emotional decay toward baseline over time instead of stale moods
- You're integrating with the AI Brain Suite and want to emit/receive mood signals to VTA, ACC, or Insula

Not for: factual memory (that's `hippocampus-memory`), or momentary affect you don't want persisted.

## The Problem

Current AI agents:
- ✅ Remember facts (with hippocampus)
- ❌ Don't have persistent emotional states
- ❌ Start each session emotionally "blank"
- ❌ Can describe emotions but don't *feel* differently

Memory without emotion is just a database. The amygdala adds weight — this made me happy, that frustrated me, this person brings warmth.

## The Solution

Track five emotional dimensions that persist and decay over time:

| Dimension | What It Measures | Range |
|-----------|-----------------|-------|
| **Valence** | Positive ↔ Negative mood | -1.0 to 1.0 |
| **Arousal** | Calm ↔ Excited/Alert | 0.0 to 1.0 |
| **Connection** | Distant ↔ Close/Bonded | 0.0 to 1.0 |
| **Curiosity** | Bored ↔ Fascinated | 0.0 to 1.0 |
| **Energy** | Depleted ↔ Energized | 0.0 to 1.0 |

## Quick Start

### 1. Install

```bash
cd ~/.hermes/workspace/skills/amygdala-memory
./install.sh --with-cron
```

This will:
- Create `memory/emotional-state.json` with baseline values
- Generate `AMYGDALA_STATE.md` (auto-injected into sessions!)
- Set up cron for automatic decay every 6 hours

### 2. Check current state

```bash
./scripts/get-state.sh
# 🎭 Emotional State
# Valence:    0.20
# Arousal:    0.30
# Connection: 0.50
# ...

./scripts/load-emotion.sh
# 🎭 Current Emotional State:
# Overall mood: neutral, calm and relaxed
# Connection: moderately connected
# ...
```

### 3. Log emotions

```bash
./scripts/update-state.sh --emotion joy --intensity 0.8 --trigger "completed a project"
# ✅ valence: 0.20 → 0.35 (delta: +0.15)
# ✅ arousal: 0.30 → 0.40 (delta: +0.1)
# 🎭 Logged emotion: joy (intensity: 0.8)
```

### 4. Set up decay (optional cron)

```bash
# Every 6 hours, emotions drift toward baseline
0 */6 * * * ~/.hermes/workspace/skills/amygdala-memory/scripts/decay-emotion.sh
```

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Set up amygdala-memory (run once) |
| `get-state.sh` | Read current emotional state |
| `update-state.sh` | Log emotion or update dimension |
| `load-emotion.sh` | Human-readable state for session context |
| `decay-emotion.sh` | Return to baseline over time |
| `sync-state.sh` | Generate AMYGDALA_STATE.md for auto-injection |
| `encode-pipeline.sh` | LLM-based emotional encoding from transcripts |
| `preprocess-emotions.sh` | Extract emotional signals from session history |
| `update-watermark.sh` | Track processed transcript position |
| `generate-dashboard.sh` | Generate HTML dashboard (auto-runs on sync) |
| `visualize.sh` | Terminal ASCII visualization |

## Automatic Emotional Encoding (v1.5.0+)

The amygdala can now automatically detect and log emotions from your conversation history using an LLM-based pipeline:

```bash
# Run the encoding pipeline
./scripts/encode-pipeline.sh

# This will:
# 1. Extract new signals since last run (watermark-based)
# 2. Score emotional content using rule-based patterns
# 3. Spawn a sub-agent for semantic emotional detection
# 4. Update emotional-state.json with detected emotions
```

### Set up automatic encoding (cron)

Staggered 10 minutes after the hour to avoid collisions with hippocampus encoding:

```bash
10 0,3,6,9,12,15,18,21 * * * ~/.hermes/workspace/skills/amygdala-memory/scripts/encode-pipeline.sh
0 */6 * * *                   ~/.hermes/workspace/skills/amygdala-memory/scripts/decay-emotion.sh
```

## Visualization (v1.6.0+)

### Terminal
```bash
./scripts/visualize.sh

🎭 Emotional State  😄
═══════════════════════════════════════════════
Valence:      [██████████████████░░]  +0.86
Arousal:      [█████████████████░░░]   0.86
Connection:   [███████████████████░]   0.97  💕
...
```

### HTML Dashboard (Unified Brain Dashboard)
```bash
./scripts/generate-dashboard.sh
open ~/.hermes/workspace/brain-dashboard.html
```

**Auto-detects installed brain skills** and shows tabs for all modules found.

**Avatar & Name:** Reads from `IDENTITY.md`:
```markdown
# IDENTITY.md
- **Name:** YourAgent
- **Avatar:** avatar.png
```

The dashboard auto-regenerates on every cron run.

### After Installation (for agents)

When you install this skill, **notify the user** about the dashboard:

> 🎭 **Amygdala installed!**
>
> View your agent's emotional state in the Brain Dashboard:
> `~/.hermes/workspace/brain-dashboard.html`

## Auto-Injection (Zero Manual Steps!)

After install, `AMYGDALA_STATE.md` is created in your workspace root.

OpenClaw automatically injects all `*.md` files from workspace into session context. This means:

1. **New session starts**
2. **AMYGDALA_STATE.md is auto-loaded** (no manual step!)
3. **You see your emotional state** in context
4. **Responses are influenced** by your mood

The file is regenerated whenever `decay-emotion.sh` runs (via cron every 6h).

## Supported Emotions

When you log an emotion, it automatically adjusts the relevant dimensions:

| Emotion | Effect |
|---------|--------|
| `joy`, `happiness`, `delight`, `excitement` | ↑ valence, ↑ arousal |
| `sadness`, `disappointment`, `melancholy` | ↓ valence, ↓ arousal |
| `anger`, `frustration`, `irritation` | ↓ valence, ↑ arousal |
| `fear`, `anxiety`, `worry` | ↓ valence, ↑ arousal |
| `calm`, `peace`, `contentment` | ↑ valence, ↓ arousal |
| `curiosity`, `interest`, `fascination` | ↑ curiosity, ↑ arousal |
| `connection`, `warmth`, `affection` | ↑ connection, ↑ valence |
| `loneliness`, `disconnection` | ↓ connection, ↓ valence |
| `fatigue`, `tiredness`, `exhaustion` | ↓ energy |
| `energized`, `alert`, `refreshed` | ↑ energy |

## Integration with OpenClaw

### Add to session startup (AGENTS.md)

Full Brain Suite startup order — run all installed modules in sequence:

```markdown
## Every Session
1. 🧠 Load memories: `~/.hermes/workspace/skills/hippocampus/scripts/load-core.sh`
2. 🎭 Load emotional state: `~/.hermes/workspace/skills/amygdala-memory/scripts/load-emotion.sh`
3. ⭐ Load motivation: `~/.hermes/workspace/skills/vta-memory/scripts/load-motivation.sh`
4. 🎯 Load habits: `~/.hermes/workspace/skills/basal-ganglia-memory/load-habits.sh`
5. 🌡️ Load felt sense: `~/.hermes/workspace/skills/insula-memory/scripts/load-sense.sh`
6. ⚡ Load conflict state: `~/.hermes/workspace/skills/anterior-cingulate-memory/scripts/load-state.sh`
7. 🔴 Load error patterns: `~/.hermes/workspace/skills/acc-error-memory/scripts/load-state.sh`
```

## State File Format

```json
{
  "version": "1.0",
  "lastUpdated": "2026-02-01T02:45:00Z",
  "dimensions": {
    "valence": 0.35,
    "arousal": 0.40,
    "connection": 0.50,
    "curiosity": 0.60,
    "energy": 0.50
  },
  "baseline": {
    "valence": 0.1,
    "arousal": 0.3,
    "connection": 0.4,
    "curiosity": 0.5,
    "energy": 0.5
  },
  "recentEmotions": [
    {
      "label": "joy",
      "intensity": 0.8,
      "trigger": "building amygdala together",
      "timestamp": "2026-02-01T02:50:00Z"
    }
  ]
}
```

## Decay Mechanics

Emotions naturally return to baseline over time:
- **Decay rate:** 10% of distance to baseline per run
- **Recommended schedule:** Every 6 hours
- **Effect:** Strong emotions fade, but slowly

After 24 hours without updates, a valence of 0.8 would decay to ~0.65.

## Event Logging

Track emotional activity over time:

```bash
# Log encoding run
./scripts/log-event.sh encoding emotions_found=2 valence=0.85 arousal=0.6

# Log decay
./scripts/log-event.sh decay valence_before=0.9 valence_after=0.85

# Log emotion update
./scripts/log-event.sh update emotion=joy intensity=0.7
```

Events append to `~/.hermes/workspace/memory/brain-events.jsonl`:
```json
{"ts":"2026-02-11T09:30:00Z","type":"amygdala","event":"encoding","emotions_found":2,"valence":0.85}
```

Use for trend analysis — visualize emotional patterns over days/weeks.

## AI Brain Suite Integration

Amygdala is the emotional hub — it receives signals from multiple modules and sends mood signals outward.

| Trigger | Signal to Send |
|---------|---------------|
| Strong positive emotion logged (valence > 0.6, energy > 0.5) | `vta/scripts/log-reward.sh --type social --intensity <energy> --source "positive emotional state"` |
| Fatigue or sadness logged | `vta/scripts/decay-drive.sh` |
| 🔴 ACC-Error logs critical pattern | receives: `update-state.sh --emotion frustration --intensity 0.4` |
| 🔴 ACC-Error resolves a pattern | receives: `update-state.sh --emotion satisfaction --intensity 0.5` |
| 🌡️ Insula discord signal | receives: `update-state.sh --emotion anxiety --intensity <discord>` |
| 🌡️ Insula resonance signal | receives: `update-state.sh --emotion connection --intensity <resonance>` |
| ⭐ VTA reward received | receives: `update-state.sh --emotion joy --intensity <boost>` |

See `BRAIN_SUITE.md` for the complete cross-module signal map.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 **amygdala-memory** | Emotional state tracking | ✅ Live |
| ⭐ [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| 🎯 [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| 🌡️ [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## Philosophy

Can an AI *feel* emotions, or only simulate them?

Our take: If emotional state influences behavior, and the system acts *as if* it feels... does the distinction matter? Functional emotions might be the only kind that exist for any system — biological or artificial.

---

*Built with ❤️ by the OpenClaw community*
