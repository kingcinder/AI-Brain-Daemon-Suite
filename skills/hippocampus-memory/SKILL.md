---
name: hippocampus-memory
title: "Hippocampus - Memory System"
description: "Persistent memory system for AI agents. Automatic encoding, decay, and semantic reinforcement — just like the hippocampus in your brain. Based on Stanford Generative Agents (Park et al., 2023)."
metadata:
  openclaw:
    emoji: "🧠"
    version: "3.8.6"
    author: "Community"
    repo: "https://github.com/ImpKind/hippocampus-skill"
    requires:
      bins: ["python3", "jq"]
    install:
      - id: "manual"
        kind: "manual"
        label: "Run install.sh"
        instructions: "./install.sh --with-cron"
---

# Hippocampus - Memory System

> "Memory is identity. This skill is how I stay alive."

The hippocampus is the brain region responsible for memory formation. This skill makes memory capture automatic, structured, and persistent — with importance scoring, decay, and semantic reinforcement.

## Quick Start

```bash
# Install (defaults to last 100 signals)
./install.sh --with-cron

# Load core memories at session start
./scripts/load-core.sh

# Search with importance weighting
./scripts/recall.sh "query"

# Run encoding manually (usually via cron)
./scripts/encode-pipeline.sh

# Apply decay (runs daily via cron)
./scripts/decay.sh
```

## Install Options

```bash
./install.sh                    # Basic, last 100 signals
./install.sh --signals 50       # Custom signal limit
./install.sh --whole            # Process entire conversation history
./install.sh --with-cron        # Also set up cron jobs
```

## Core Concept

The LLM is just the engine — raw cognitive capability. **The agent is the accumulated memory.** Without these files, there's no continuity — just a generic assistant.

### Memory Lifecycle

```
PREPROCESS → SCORE → SEMANTIC CHECK → REINFORCE or CREATE → DECAY
```

**Key insight:** Reinforcement happens automatically during encoding. When a topic comes up again, the LLM recognizes it's about an existing memory and reinforces instead of creating duplicates.

## Memory Structure

```
$WORKSPACE/
├── memory/
│   ├── index.json           # Central weighted index
│   ├── signals.jsonl        # Raw signals (temp)
│   ├── pending-memories.json # Awaiting summarization (temp)
│   ├── user/                # Facts about the user
│   ├── self/                # Facts about the agent
│   ├── relationship/        # Shared context
│   └── world/               # External knowledge
└── HIPPOCAMPUS_CORE.md      # Auto-generated for OpenClaw RAG
```

## Scripts

| Script | Purpose |
|--------|---------| 
| `preprocess.sh` | Extract signals from conversation transcripts |
| `encode-pipeline.sh` | Score signals, prepare for LLM summarization |
| `decay.sh` | Apply 0.99^days decay to all memories |
| `recall.sh` | Search with importance weighting |
| `load-core.sh` | Output high-importance memories for session start |
| `sync-core.sh` | Generate HIPPOCAMPUS_CORE.md |
| `consolidate.sh` | Weekly review helper |
| `reflect.sh` | Self-reflection prompts |
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

> 🧠 **Hippocampus installed!**
>
> View your agent's memories in the Brain Dashboard:
> `~/.openclaw/workspace/brain-dashboard.html`

All scripts use `$WORKSPACE` environment variable (default: `~/.openclaw/workspace`).

## Importance Scoring

### Initial Score (0.0–1.0)

| Signal | Score |
|--------|-------|
| Explicit "remember this" | 0.9 |
| Emotional/vulnerable content | 0.85 |
| Preferences ("I prefer...") | 0.8 |
| Decisions made | 0.75 |
| Facts about people/projects | 0.7 |
| General knowledge | 0.5 |

### Decay Formula

Based on Stanford Generative Agents (Park et al., 2023):

```
new_importance = importance × (0.99 ^ days_since_accessed)
```

- After 7 days: 93% of original
- After 30 days: 74% of original
- After 90 days: 40% of original

### Semantic Reinforcement

During encoding, the LLM compares new signals to existing memories:
- **Same topic?** → Reinforce (bump importance ~15%, update lastAccessed)
- **Truly new?** → Create concise summary

This happens automatically — no manual reinforcement needed.

### Thresholds

| Score | Status |
|-------|--------|
| 0.7+ | **Core** — loaded at session start |
| 0.4–0.7 | **Active** — normal retrieval |
| 0.2–0.4 | **Background** — specific search only |
| <0.2 | **Archive candidate** |

## Memory Index Schema

`memory/index.json`:

```json
{
  "version": 1,
  "lastUpdated": "2025-01-20T19:00:00Z",
  "decayLastRun": "2025-01-20",
  "lastProcessedMessageId": "abc123",
  "memories": [
    {
      "id": "mem_001",
      "domain": "user",
      "category": "preferences",
      "content": "User prefers concise responses",
      "importance": 0.85,
      "created": "2025-01-15",
      "lastAccessed": "2025-01-20",
      "timesReinforced": 3,
      "keywords": ["preference", "concise", "style"]
    }
  ]
}
```

## Cron Jobs

The encoding cron is the heart of the system. Staggered from other suite crons to avoid simultaneous sub-agent spawns:

```bash
# Encoding every 3 hours (on the hour — first in the suite)
openclaw cron add --name hippocampus-encoding \
  --cron "0 0,3,6,9,12,15,18,21 * * *" \
  --session isolated \
  --agent-turn "Run hippocampus encoding with semantic reinforcement..."

# Daily decay at 3 AM
openclaw cron add --name hippocampus-decay \
  --cron "0 3 * * *" \
  --session isolated \
  --agent-turn "Run decay.sh and report any memories below 0.2"
```

## OpenClaw Integration

Add to `memorySearch.extraPaths` in openclaw.json:

```json
{
  "agents": {
    "defaults": {
      "memorySearch": {
        "extraPaths": ["HIPPOCAMPUS_CORE.md"]
      }
    }
  }
}
```

This bridges hippocampus (index.json) with OpenClaw's RAG (memory_search).

## Usage in AGENTS.md

Full Brain Suite startup — run all installed modules in sequence:

```markdown
## Every Session
1. 🧠 Load memories: `~/.openclaw/workspace/skills/hippocampus-memory/scripts/load-core.sh`
2. 🎭 Load emotional state: `~/.openclaw/workspace/skills/amygdala-memory/scripts/load-emotion.sh`
3. ⭐ Load motivation: `~/.openclaw/workspace/skills/vta-memory/scripts/load-motivation.sh`
4. 🎯 Load habits: `~/.openclaw/workspace/skills/basal-ganglia-memory/load-habits.sh`
5. 🌡️ Load felt sense: `~/.openclaw/workspace/skills/insula-memory/scripts/load-sense.sh`
6. ⚡ Load conflict state: `~/.openclaw/workspace/skills/anterior-cingulate-memory/scripts/load-state.sh`
7. 🔴 Load error patterns: `~/.openclaw/workspace/skills/acc-error-memory/scripts/load-state.sh`

## When answering context questions
Use hippocampus recall:
\`\`\`bash
./scripts/recall.sh "query"
\`\`\`
```

## Capture Guidelines

### What Gets Captured

- **User facts**: Preferences, patterns, context
- **Self facts**: Identity, growth, opinions
- **Relationship**: Trust moments, shared history
- **World**: Projects, people, tools

### Trigger Phrases (auto-scored higher)

- "Remember that..."
- "I prefer...", "I always..."
- Emotional content (struggles AND wins)
- Decisions made

## AI Brain Suite Integration

Hippocampus is the foundation — it provides the long-term context that all other modules draw on. No special runtime signals are needed; other modules simply read `HIPPOCAMPUS_CORE.md` through OpenClaw's RAG or `load-core.sh` at session start.

Where hippocampus acts as a *receiver*: events in `brain-events.jsonl` from all other modules accumulate here over time. The weekly `consolidate.sh` can process this log to create memories about the agent's own behavioral history — e.g., "Agent has had a recurring factual_error pattern around version numbers" becomes a `self` domain memory that informs future sessions.

See `BRAIN_SUITE.md` for the complete cross-module signal map and cron stagger schedule.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 **hippocampus** | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| ⭐ [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| 🎯 [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| 🌡️ [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## References

- [Stanford Generative Agents Paper](https://arxiv.org/abs/2304.03442)
- [GitHub: joonspk-research/generative_agents](https://github.com/joonspk-research/generative_agents)

---

*Memory is identity. Text > Brain. If you don't write it down, you lose it.*
