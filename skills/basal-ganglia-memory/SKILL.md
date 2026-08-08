---
name: basal-ganglia-memory
description: "Habit formation and procedural learning for AI agents. Develops preferences and shortcuts through repetition. Tracks cue-routine-reward loops, chunked procedures, and active suppressions. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🎯"
    tags: ["memory", "habits", "procedural", "ai-brain"]
  openclaw:
    emoji: "🎯"
    version: "0.2.2"
    author: "ImpKind"
    requires:
      os: ["darwin", "linux"]
      tools: ["python3", "jq"]
    tags: ["memory", "habits", "procedural", "ai-brain"]
---

# Basal Ganglia Memory 🎯

**Habit formation and procedural learning for AI agents.** Part of the AI Brain series.

The basal ganglia is the brain region responsible for chunking repeated behaviors into automatic routines — turning deliberate actions into effortless habits. This skill brings the same mechanism to AI agents: patterns that appear repeatedly crystallize into habits, multi-step workflows compact into procedures, and corrections that stick become suppressions.

## When to Use

Use this skill when:
- A behavior or workflow has repeated successfully and should become an automatic routine
- You've been corrected on a pattern and want a suppression so it stops recurring
- You want session-start injection of established habits (`load-habits.sh`)
- You're integrating with the AI Brain Suite and want `acc-error-memory` corrections to close into suppressions

Not for: one-off tasks, or execution quality tracking (that's `cerebellum-memory`).

---

## Quick Start

```bash
# Install
./install.sh

# First encoding (process last 100 signals)
./scripts/encode-pipeline.sh

# Load habits into context
./load-habits.sh

# View full habit state
./get-habits.sh
```

---

## How It Works

### The Cue → Routine → Reward Loop

Every habit is stored as three components:

- **Cue** — The trigger that activates the habit ("When the user asks about code…")
- **Routine** — The automatic behavior that fires ("…I check for existing tests first")
- **Reward** — Why this pattern persists ("…because it catches silent regressions")

### Habit Strength (0.0 – 1.0)

| Strength | Status | Description |
|----------|--------|-------------|
| ≥ 0.70 | 🟢 chunked | Fires automatically when cue appears |
| ≥ 0.40 | 🟡 active | Apply deliberately — still solidifying |
| ≥ 0.20 | 🟠 forming | Pattern emerging, needs more repetitions |
| < 0.20 | ⚪ candidate | Weak signal, watch for recurrence |

### Reinforcement

Each time a habit fires successfully, strength moves toward 1.0 by 12% of remaining headroom:

```
new_strength = old + (1 - old) × 0.12
```

Negative outcomes move it the other direction (weakening). Habits that aren't fired decay over time (default: 3% per day).

### Procedures

Procedures are multi-step **workflows** that have been chunked into a named routine. Instead of a single cue→routine pair, a procedure tracks an ordered list of steps that reliably achieve a goal:

```json
{
  "id": "proc_001",
  "name": "Debug session opener",
  "steps": ["Read error message carefully", "Reproduce in isolation", "Check recent changes", "Add logging"],
  "strength": 0.75
}
```

### Suppressions

Suppressions are **anti-habits** — patterns the agent was corrected on and should actively avoid. They decay much more slowly than regular habits (0.5% per day vs 3%) because corrections are meant to stick:

```json
{
  "id": "sup_001",
  "pattern": "Suggesting library X for task Y",
  "reason": "User strongly prefers vanilla implementations",
  "strength": 0.85
}
```

---

## File Structure

```
basal-ganglia-memory/
├── SKILL.md                    ← This file
├── README.md                   ← Human-readable guide
├── ARCHITECTURE.md             ← Technical design
├── install.sh                  ← One-time setup
├── get-habits.sh               ← Read habit state (table view)
├── load-habits.sh              ← Context injection (session start)
├── reinforce-habit.sh          ← Create/reinforce/weaken habits
├── log-event.sh                ← Append to brain-events.jsonl (type: basal-ganglia)
├── update-watermark.sh         ← Advance signal watermark
├── prompts/
│   └── encode-habits.md        ← LLM prompt for habit classification
└── scripts/
    ├── preprocess-habits.sh    ← Transcript → habit-signals.jsonl
    ├── encode-pipeline.sh      ← Full encoding orchestration
    ├── decay-habits.sh         ← Time-based strength decay
    ├── sync-state.sh           ← Sync to BASAL_GANGLIA_STATE.md
    └── generate-dashboard.sh   ← Extend brain-dashboard.html
```

---

## Encoding Pipeline

The encoding pipeline runs on a schedule (or manually) and follows these steps:

1. **Preprocess** — Scan conversation transcripts for habit signals; output `memory/habit-signals.jsonl`
2. **Score** — Apply heuristics to score signals (explicit instructions score high, single observations score low)
3. **Prepare** — Write `memory/pending-habits.json` with signals that need LLM classification
4. **Sub-agent** — LLM reads `pending-habits.json` and `prompts/encode-habits.md`, then calls `reinforce-habit.sh` for each signal
5. **Watermark** — Advance `lastProcessedSignal` so we don't re-process old signals
6. **Sync** — Regenerate `BASAL_GANGLIA_STATE.md` and `brain-dashboard.html`

### Manual Encoding

```bash
# Run the full pipeline (spawns sub-agent for LLM step)
./scripts/encode-pipeline.sh

# Run without spawning (useful for testing)
./scripts/encode-pipeline.sh --no-spawn
```

### Cron Encoding

Staggered 30 minutes after the hour to avoid collisions with other suite crons:

```bash
30 0,3,6,9,12,15,18,21 * * *  ~/.hermes/workspace/skills/basal-ganglia-memory/scripts/encode-pipeline.sh
0 4 * * *                       ~/.hermes/workspace/skills/basal-ganglia-memory/scripts/decay-habits.sh
```

Install with `./install.sh --with-cron` to register both.

---

## Context Injection

At session start, call `load-habits.sh` to inject active habits into context:

```bash
# Prose format (default, inject into system prompt)
./load-habits.sh

# Brief summary
./load-habits.sh --format brief

# JSON (for programmatic use)
./load-habits.sh --format json
```

Example output:
```
🎯 BASAL GANGLIA: habits and routines for this session

Chunked (fire automatically when the cue appears):
  • When starting a code review → read tests first  (strength 0.84, 23 runs)

Suppressions (actively avoid these patterns):
  • Avoid: suggesting rewrites without measuring first — User prefers iteration
```

---

## Manual Operations

### Create a new habit

```bash
./reinforce-habit.sh --new \
  --cue "User asks for a code review" \
  --routine "Check test coverage before reading the code" \
  --reward "Surfaces blind spots early" \
  --category workflow \
  --strength 0.6
```

### Reinforce an existing habit

```bash
./reinforce-habit.sh --id habit_001
```

### Weaken a habit (it misfired)

```bash
./reinforce-habit.sh --id habit_001 --weaken --note "Gave wrong advice for this case"
```

### Create a procedure

```bash
./reinforce-habit.sh --new --type procedure \
  --name "Debugging session opener" \
  --steps "Read error message,Reproduce in isolation,Check git log,Add logging" \
  --category debugging \
  --strength 0.5
```

### Add a suppression

```bash
./reinforce-habit.sh --suppress "Suggesting library X for async work" \
  --reason "User always wants raw asyncio" \
  --strength 0.75
```

### Run decay manually

```bash
./scripts/decay-habits.sh
```

---

## Data Files

All data lives under `$WORKSPACE/memory/` (default: `~/.hermes/workspace/memory/`):

| File | Description |
|------|-------------|
| `habit-state.json` | Central state: habits, procedures, suppressions |
| `habit-signals.jsonl` | Preprocessed signals from transcripts |
| `pending-habits.json` | Signals awaiting LLM classification |
| `brain-events.jsonl` | Append-only event log |

The sync script also writes:

| File | Description |
|------|-------------|
| `$WORKSPACE/BASAL_GANGLIA_STATE.md` | Chunked habits for context injection |
| `$WORKSPACE/brain-dashboard.html` | Visual dashboard (extended with 🎯 Habits tab) |

### habit-state.json Schema

```json
{
  "version": "1.0",
  "lastUpdated": "2026-06-15T10:00:00Z",
  "decayLastRun": "2026-06-15",
  "lastProcessedSignal": "msg_abc123",
  "habits": [
    {
      "id": "habit_001",
      "cue": "User asks to review code",
      "routine": "Read tests before reading implementation",
      "reward": "Catches gaps the implementation hides",
      "strength": 0.84,
      "status": "chunked",
      "executions": 23,
      "lastFired": "2026-06-14T18:30:00Z",
      "created": "2026-05-01T09:00:00Z",
      "category": "workflow",
      "tags": ["code", "review"]
    }
  ],
  "procedures": [
    {
      "id": "proc_001",
      "name": "Debug session opener",
      "steps": ["Read error message carefully", "Reproduce in isolation"],
      "strength": 0.65,
      "executions": 7,
      "lastUsed": "2026-06-10T14:00:00Z",
      "created": "2026-05-15T11:00:00Z",
      "category": "debugging"
    }
  ],
  "suppressions": [
    {
      "id": "sup_001",
      "pattern": "Suggesting rewrites before measuring",
      "reason": "User prefers incremental improvement",
      "strength": 0.85,
      "created": "2026-05-10T09:00:00Z",
      "lastReinforced": "2026-06-01T12:00:00Z"
    }
  ]
}
```

---

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

---

## AI Brain Suite Integration

Habits form at the intersection of behavior and reward. Two natural integration points:

| Trigger | Signal to Send |
|---------|---------------|
| Chunked habit fires successfully | `vta/scripts/log-reward.sh --type competence --intensity 0.5 --source "habit fired: <cue>"` |
| Habit fires and user responds positively | `amygdala/scripts/update-state.sh --emotion satisfaction --intensity 0.3 --trigger "habit success: <cue>"` |
| 🔴 ACC-Error recurring pattern (3+) | receives: `reinforce-habit.sh --suppress "<pattern>" --reason "<mitigation>" --strength 0.7` |
| 🎭 Amygdala: strong joy after task | `reinforce-habit.sh --id <active_habit_id>` (reinforce the habit that completed the task) |

The **ACC-Error → Basal Ganglia** pipeline is particularly powerful: when `acc-error-memory` detects a recurring mistake (3+ occurrences), automatically creating a suppression here closes the correction loop without requiring manual intervention.

See `BRAIN_SUITE.md` for the complete cross-module signal map.

---

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| ⭐ [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| 🎯 **basal-ganglia-memory** | Habit formation and procedural learning | ✅ Live |
| 🌡️ [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

---

*Built with ❤️ by the OpenClaw community*
