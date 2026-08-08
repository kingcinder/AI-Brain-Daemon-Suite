---
name: anterior-cingulate-memory
description: "Conflict detection and uncertainty monitoring for AI agents. Tracks information conflicts, ambiguous intent, and cognitive load. The real-time 'something feels off' detector. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "⚡"
    tags: ["memory", "monitoring", "conflict", "uncertainty", "ai-brain"]
  openclaw:
    emoji: "⚡"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/anterior-cingulate-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["jq", "awk", "bc", "python3"]
    tags: ["memory", "monitoring", "conflict", "uncertainty", "ai-brain"]
---

# Anterior Cingulate Memory ⚡

**Proactive conflict detection and uncertainty monitoring for AI agents.** Part of the AI Brain series.

Give your AI agent a persistent sense of *something's off* — detecting information conflicts, flagging ambiguous intent, and tracking cognitive load across sessions. Its reactive complement, `acc-error-memory` 🔴, watches for corrections and patterns *after the fact*.

## When to Use

Use this skill when:
- Instructions or facts contradict each other and you need to flag the conflict rather than guess
- User intent is ambiguous and you should ask before proceeding
- You want an internal uncertainty meter that gates how confidently you respond
- You're integrating with the AI Brain Suite and want proactive oversight paired with `acc-error-memory`

Not for: post-hoc error learning (that's `acc-error-memory`), or clear-cut tasks with no ambiguity.

## The Problem

Current AI agents:
- ✅ Process what they're told
- ❌ Don't notice when information contradicts itself
- ❌ Don't track cumulative uncertainty
- ❌ Respond confidently even when context is ambiguous
- ❌ Have no internal signal for "I should ask before proceeding"

Without conflict detection, there's no inner alarm. Just execution — even when the instructions conflict.

## The Solution

Track **conflict load** through persistent state:

| Dimension | What It Tracks | Range |
|-----------|----------------|-------|
| **Conflict Load** | Overall uncertainty/conflict pressure | 0.0 to 1.0 |
| **Active Conflicts** | Unresolved information or instruction conflicts | — |
| **Attention Flags** | Topics that need extra care | — |
| **Uncertainty Zones** | Subject areas with high uncertainty | — |
| **Resolved Conflicts** | How past conflicts were settled (for learning) | — |

## Quick Start

### 1. Install

```bash
cd ~/.hermes/workspace/skills/anterior-cingulate-memory
./install.sh --with-cron
```

This will:
- Create `memory/conflict-state.json` with baseline values
- Generate `ACC_CONFLICT_STATE.md` (auto-injected into sessions!)
- Set up cron for conflict load decay every 4 hours

### 2. Check current state

```bash
./scripts/load-state.sh
# ⚡ Conflict State:
# Conflict load: 0.20 (clear — proceed normally)
# Active conflicts: 0
# Attention flags: 0
```

### 3. Log a conflict

```bash
./scripts/log-conflict.sh \
  --type "instruction" \
  --description "User said 'keep it short' then asked for a detailed breakdown" \
  --resolution-hint "Ask which format they prefer before responding"

# ⚡ Conflict logged: instruction
#    Load: 0.20 → 0.31 (+0.11)
```

### 4. Flag a topic for attention

```bash
./scripts/flag-attention.sh --add "API version numbers" \
  --reason "Conflicting info about v2 vs v3 endpoints in this session"

# ⚡ Flagged for attention: API version numbers
```

### 5. Resolve a conflict

```bash
./scripts/resolve-conflict.sh --id "instruction_1749852000" \
  --resolution "User clarified: short summary first, details on request"

# ⚡ Conflict resolved!
#    Load: 0.31 → 0.23 (-0.08)
```

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Set up anterior-cingulate-memory (run once) |
| `get-state.sh` | Read raw conflict state |
| `log-conflict.sh` | Log a detected conflict, raise load |
| `load-state.sh` | Human-readable state for session context |
| `resolve-conflict.sh` | Mark a conflict resolved, lower load |
| `decay-load.sh` | Conflict load fades without new conflicts |
| `flag-attention.sh` | Add/remove attention flags for risky topics |
| `sync-state.sh` | Generate ACC_CONFLICT_STATE.md for auto-injection |
| `encode-pipeline.sh` | LLM-based conflict detection from transcripts |
| `preprocess-exchanges.sh` | Extract exchanges for conflict analysis |
| `update-watermark.sh` | Track processed transcript position |
| `log-event.sh` | Log events to brain-events.jsonl (type: `acc-conflict`) |
| `generate-dashboard.sh` | Generate unified brain dashboard HTML |

## Conflict Types

| Type | When to Use |
|------|-------------|
| `factual` | Contradictory facts in conversation or knowledge |
| `instruction` | Conflicting or ambiguous user instructions |
| `context` | Missing or unclear context that changes meaning |
| `uncertainty` | High uncertainty about a claim or fact |
| `intent` | Ambiguous user intent — not clear what they want |
| `knowledge_gap` | Agent's own knowledge is insufficient to proceed |

## Conflict Load Levels

| Load | Status | Behavior |
|------|--------|----------|
| < 0.2 | 🟢 Clear | Proceed confidently |
| 0.2–0.4 | 🟡 Low | Minor ambiguities — note them |
| 0.4–0.6 | 🟠 Moderate | Verify key claims before responding |
| 0.6–0.8 | 🔴 Elevated | Ask clarifying questions before proceeding |
| > 0.8 | 🚨 Critical | Multiple unresolved conflicts — explicit caution required |

## Automatic Conflict Encoding (v1.0.0+)

The ACC can detect conflicts from conversation history using an LLM-based pipeline:

```bash
./scripts/encode-pipeline.sh

# This will:
# 1. Extract exchanges since last watermark
# 2. Score for contradiction, ambiguity, correction signals
# 3. Spawn sub-agent for semantic conflict detection
# 4. Update conflict-state.json automatically
```

Set up cron for automatic encoding (staggered 50 minutes after the hour to avoid collisions with other suite crons):

```bash
50 0,3,6,9,12,15,18,21 * * * ~/.hermes/workspace/skills/anterior-cingulate-memory/scripts/encode-pipeline.sh
0 */4 * * *                   ~/.hermes/workspace/skills/anterior-cingulate-memory/scripts/decay-load.sh
```

## Auto-Injection (Zero Manual Steps!)

After install, `ACC_CONFLICT_STATE.md` is created in your workspace root.

OpenClaw automatically injects all `*.md` files from workspace into session context:

1. **New session starts**
2. **ACC_CONFLICT_STATE.md is auto-loaded**
3. **Agent sees current conflict load and attention flags**
4. **Behavior adjusted based on uncertainty level**

## How Conflict Load Works

### Logging Raises Load
```
load_boost = intensity × 0.15
new_load = min(current + boost, 1.0)
```

A high-intensity (0.9) conflict raises load by 0.135.

### Resolution Lowers Load
```
load_reduction = intensity × 0.10
new_load = max(current - reduction, baseline)
```

### Decay Without New Conflicts
```
# Every 4 hours (via cron)
new_load = current + (baseline - current) × 0.20
```

Without new conflicts, load drifts back to baseline (0.2).

## State File Format

```json
{
  "version": "1.0",
  "lastUpdated": "2026-06-14T12:00:00Z",
  "conflictLoad": 0.35,
  "baseline": { "conflictLoad": 0.2 },
  "activeConflicts": {
    "instruction_1749852000": {
      "type": "instruction",
      "severity": "moderate",
      "intensity": 0.7,
      "description": "User said 'keep it short' then asked for detailed breakdown",
      "resolutionHint": "Ask which format they prefer",
      "firstSeen": "2026-06-14T11:00:00Z",
      "lastSeen": "2026-06-14T11:00:00Z"
    }
  },
  "attentionFlags": [
    {
      "topic": "API version numbers",
      "reason": "Conflicting info about v2 vs v3",
      "addedAt": "2026-06-14T11:05:00Z"
    }
  ],
  "uncertaintyZones": {
    "deployment_environment": {
      "level": 0.8,
      "reason": "User has not confirmed prod vs staging"
    }
  },
  "resolvedConflicts": [],
  "stats": {
    "totalConflictsLogged": 3,
    "totalResolved": 2,
    "totalAttentionFlags": 1
  }
}
```

## Event Logging

Track conflict patterns over time. All events use `"type": "acc-conflict"` to distinguish from the `"acc-error"` events written by `acc-error-memory`.

```bash
./scripts/log-event.sh encoding conflicts_found=2 load=0.45
./scripts/log-event.sh conflict type=instruction severity=high
./scripts/log-event.sh decay load_before=0.5 load_after=0.42
./scripts/log-event.sh resolved conflict_id=instruction_1749852000
```

Events append to `~/.hermes/workspace/memory/brain-events.jsonl`:
```json
{"ts":"2026-06-14T12:00:00Z","type":"acc-conflict","event":"encoding","conflicts_found":2,"load":0.45}
```

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

### Behavior Guidelines

When you see conflict load in ACC_CONFLICT_STATE.md:
- 🚨 **Critical (>0.8)** — State uncertainty explicitly before responding
- 🔴 **Elevated (0.6–0.8)** — Ask a clarifying question before proceeding
- 🟠 **Moderate (0.4–0.6)** — Verify key assumptions in your response
- 🟡 **Low (0.2–0.4)** — Note any remaining ambiguities
- 🟢 **Clear (<0.2)** — Proceed normally

## AI Brain Suite Integration

Conflict load doesn't stay in isolation — it signals adjacent modules:

| Trigger | Signal to Send |
|---------|---------------|
| Conflict logged (any severity) | `insula/scripts/update-state.sh --signal strain --intensity <intensity> --source "conflict detected: <type>"` |
| Critical conflict load (>0.8) | `vta/scripts/decay-drive.sh` (motivation suppressed while navigating high uncertainty) |
| Conflict resolved | `insula/scripts/update-state.sh --signal ease --intensity 0.4 --source "conflict resolved"` |
| High friction in Insula | (Insula → this module): `log-conflict.sh --type uncertainty --description "high internal friction"` |

See `BRAIN_SUITE.md` for the complete cross-module signal map.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| ⭐ [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| 🎯 [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| 🌡️ [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ **anterior-cingulate-memory** | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## Philosophy

The anterior cingulate cortex is the brain's alarm system for cognitive conflict — the neural circuit that fires when two competing responses are active simultaneously, when what you expected doesn't match what you got, when something feels *off* before you know why.

This skill gives AI agents that same persistent metacognitive awareness: not just processing information, but *monitoring the processing itself* — noticing when the context is ambiguous, when instructions contradict, when confidence should be lower than it is.

The goal isn't paralysis. It's calibrated caution — knowing when to ask, when to hedge, and when to proceed.

---

*Built with ⚡ by the OpenClaw community*
