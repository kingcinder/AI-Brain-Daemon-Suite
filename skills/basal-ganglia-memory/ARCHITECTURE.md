# Basal Ganglia Memory — Architecture

## Overview

A background agent that monitors conversation history and crystallizes
repeated behavioral patterns into three persistent data structures: **habits**
(cue → routine → reward loops), **procedures** (chunked multi-step workflows),
and **suppressions** (actively-avoided anti-patterns). Each structure carries a
continuous `strength` score that rises with reinforcement and decays with
inactivity — simulating the biological mechanism by which deliberate actions
become automatic routines.

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       MAIN SESSION                           │
│                  (the agent + the user)                      │
│                                                              │
│  Agent acts, is corrected, or completes workflows.           │
│  No capture burden — conversation flows naturally.           │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             │ cron every 3 hours
                             ▼
┌──────────────────────────────────────────────────────────────┐
│               ENCODING PIPELINE (encode-pipeline.sh)         │
│                                                              │
│  1. preprocess-habits.sh  → habit-signals.jsonl              │
│     (Scan transcripts, apply watermark)                      │
│                                                              │
│  2. encode-pipeline.sh scoring phase                         │
│     (Heuristic scoring: habit / procedure / suppression /    │
│      reinforcement candidate)                                │
│     → pending-habits.json                                    │
│                                                              │
│  3. Sub-agent / LLM classification                           │
│     (Reads pending-habits.json + prompts/encode-habits.md,   │
│      calls reinforce-habit.sh for each signal)               │
│                                                              │
│  4. Watermark advance + sync                                 │
│     (update-watermark.sh → sync-state.sh)                    │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                      HABIT STORE                             │
│            (memory/habit-state.json)                         │
│                                                              │
│  habits[]       — cue → routine → reward, strength 0–1       │
│  procedures[]   — named multi-step workflows, strength 0–1   │
│  suppressions[] — anti-patterns to actively avoid            │
└──────────────────────────────────────────────────────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
    BASAL_GANGLIA_STATE.md  brain-dashboard.html  load-habits.sh
    (context injection)     (visual dashboard)    (session start)
```

---

## File Layout

```
basal-ganglia-memory/         ← SKILL ROOT
│
│   ── User-facing CLI tools (run directly by agent or human) ──
├── install.sh                Setup: state file, crons, first sync
├── get-habits.sh             View habit state (table or JSON)
├── load-habits.sh            Context injection at session start
├── reinforce-habit.sh        Create / reinforce / weaken / suppress
├── log-event.sh              Append to brain-events.jsonl
├── update-watermark.sh       Advance lastProcessedSignal
│
│   ── Documentation ──
├── SKILL.md                  Full reference (OpenClaw index)
├── README.md                 Human-readable guide
├── ARCHITECTURE.md           This file
├── CHANGELOG.md              Version history
├── skill-card.md             OpenClaw marketplace card
├── _meta.json                Version metadata
│
│   ── LLM instructions ──
├── prompts/
│   └── encode-habits.md      Sub-agent classification prompt
│
│   ── Pipeline internals ──
└── scripts/
    ├── preprocess-habits.sh  Transcripts → habit-signals.jsonl
    ├── encode-pipeline.sh    Orchestrates the full encoding run
    ├── decay-habits.sh       Time-based strength decay
    ├── sync-state.sh         → BASAL_GANGLIA_STATE.md + dashboard
    └── generate-dashboard.sh Writes/extends brain-dashboard.html
```

### Layout convention

Top-level scripts (`*.sh` at the skill root) are **user-facing CLI tools**
that agents call directly. Scripts in `scripts/` are **pipeline internals**
called by the pipeline, crons, and each other.

Within `scripts/`, `SKILL_DIR` always resolves to the skill root:
```bash
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
```
Within root-level scripts, `SKILL_DIR` resolves to itself:
```bash
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
```

---

## Habit State Schema

`memory/habit-state.json`:

```json
{
  "version": "1.0",
  "lastUpdated": "2026-06-15T10:00:00Z",
  "decayLastRun": "2026-06-15",
  "lastProcessedSignal": "2026-06-15T09:45:00Z",

  "habits": [
    {
      "id": "habit_001",
      "cue": "User asks for a code review",
      "routine": "Read tests before reading implementation",
      "reward": "Catches gaps the implementation hides",
      "strength": 0.84,
      "status": "chunked",
      "executions": 23,
      "lastFired": "2026-06-14T18:30:00Z",
      "created": "2026-05-01T09:00:00Z",
      "category": "workflow",
      "tags": ["code", "review"],
      "lastNote": "Optional note on most recent reinforcement"
    }
  ],

  "procedures": [
    {
      "id": "proc_001",
      "name": "Debug session opener",
      "steps": [
        "Read error message carefully",
        "Reproduce in isolation",
        "Check recent git changes",
        "Add targeted logging"
      ],
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
      "reason": "User prefers incremental improvement with metrics",
      "strength": 0.85,
      "created": "2026-05-10T09:00:00Z",
      "lastReinforced": "2026-06-01T12:00:00Z"
    }
  ]
}
```

---

## Strength Math

### Reinforcement (positive)
```
new_strength = old + (1 - old) × 0.12
```
Each successful execution closes 12% of the gap to 1.0. Logarithmic
approach means early gains are fast, later gains are slower — matching
the biology of skill acquisition.

### Weakening (negative reinforcement)
```
new_strength = old - old × 0.12
```
The routine fired but the outcome was wrong. Symmetrical: closes 12% of
the gap toward 0.

### Decay (time-based inactivity)

| Type | Formula | Rate |
|------|---------|------|
| Habits | `strength × 0.97^days_since_lastFired` | ~3%/day |
| Procedures | `strength × 0.97^days_since_lastUsed` | ~3%/day |
| Suppressions | `strength × 0.995^days_since_lastReinforced` | ~0.5%/day |

Suppressions decay much more slowly because corrections are intended to
persist even when the triggering situation isn't frequent.

### Status thresholds

| Range | Status | Behavior |
|-------|--------|---------|
| ≥ 0.70 | 🟢 **chunked** | Fires automatically when cue is recognized |
| ≥ 0.40 | 🟡 **active** | Applied deliberately — still solidifying |
| ≥ 0.20 | 🟠 **forming** | Emerging pattern, needs more repetition |
| < 0.20 | ⚪ **candidate** | Weak signal; eligible for pruning |

---

## Encoding Pipeline Details

### Signal scoring heuristics

The pipeline's Python scoring phase assigns each conversation turn a
preliminary score and type without LLM calls:

| Pattern | Score | Type |
|---------|-------|------|
| Correction language ("never", "don't", "wrong") | 0.80 | suppression |
| Explicit instruction ("always", "from now on") | 0.80 | habit |
| Multi-step workflow (numbered steps, → arrows) | 0.65 | procedure |
| Routine description from assistant | 0.55 | habit |
| Substantial user input (>100 chars) | 0.40 | habit |

Signals that **word-overlap ≥ 35%** with an existing item get
`suggested_type = "reinforcement"` and skip LLM classification entirely —
they're reinforced in the scoring phase for efficiency.

### Sub-agent classification

Signals that pass scoring but don't match an existing item go into
`pending-habits.json` for the LLM sub-agent. The sub-agent reads:
- `pending-habits.json` (pre-scored signals)
- `habit-state.json` (current state, for duplicate checking)
- `prompts/encode-habits.md` (classification instructions)

It then calls `reinforce-habit.sh` for each signal and cleans up.

### Watermark tracking

`lastProcessedSignal` in `habit-state.json` stores the ISO-8601 timestamp
of the most recent processed turn. Since signal IDs are timestamps,
`preprocess-habits.sh` uses this as a `watermark_ts` cutoff: only turns
**after** the watermark are included in subsequent runs.

---

## Context Injection

At session start, the agent loads active habits via `load-habits.sh`:

```
🎯 BASAL GANGLIA: habits and routines for this session

Chunked (fire automatically when the cue appears):
  • When starting a code review → read tests first  (0.84, 23 runs)
  • When user asks for an estimate → surface assumptions first  (0.72, 11 runs)

Suppressions (actively avoid these patterns):
  • Avoid: suggesting rewrites without measuring — User prefers iteration
```

The equivalent Markdown file (`BASAL_GANGLIA_STATE.md` in workspace root)
is also available for the legacy memory_search / extraPaths injection (OpenClaw openclaw.json; Hermes reads AGENTS.md instead).

---

## Dashboard Integration

`generate-dashboard.sh` writes the shared `brain-dashboard.html`, adding a
**🎯 Habits** tab. The tab shows:
- 4-up stat counters (chunked/total habits/procedures/suppressions)
- Habit strength bars (cue → routine, colored by status)
- Procedures with step chains
- Suppressions as warning tags

The basal-ganglia version sets itself as the active tab by default.
Each brain skill maintains its own copy of `generate-dashboard.sh`; the
last one to run "wins" the active tab.

---

## Integration with Other Brain Skills

| Skill | Relationship |
|-------|-------------|
| **hippocampus** | Complementary: hippocampus encodes *what happened* (episodic); basal-ganglia encodes *what to do* (procedural). Dashboard is shared. |
| **amygdala** | Future: emotional valence of a habit's reward could influence reinforcement rate. |
| **vta** | Future: VTA's dopamine-drive signal could modulate how quickly candidate habits become active. |
| **anterior-cingulate** (planned) | Will detect when a chunked habit is firing in the wrong context — triggering weakening. |
| **insula** (planned) | Internal state signals may modulate which habits are contextually appropriate. |

---

## Cron Schedule

| Job | Schedule | Script |
|-----|---------|--------|
| `basal-ganglia-encoding` | Every 3 hours (0,3,6,9,12,15,18,21) | `scripts/encode-pipeline.sh` |
| `basal-ganglia-decay` | Daily at 04:00 | `scripts/decay-habits.sh` |

---

## Future Enhancements

1. **Contextual activation** — Only surface habits whose category matches the current session's context (e.g., only show `debugging` habits when an error is present)
2. **Emotional valence gating** — If amygdala valence is very low, suppress habit firing until mood recovers
3. **Habit chaining** — Link habits so completing one fires the next (like a reflex arc)
4. **Strength floor for core suppressions** — Mark critical suppressions as non-decaying
5. **Semantic similarity** — Replace word-overlap matching with embedding-based similarity for better reinforcement detection
6. **Sleep consolidation** — Weekly batch that reviews all candidates and promotes/prunes based on cross-session frequency
