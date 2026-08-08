# Basal Ganglia Memory 🎯

> *"We are what we repeatedly do. Excellence, then, is not an act, but a habit."* — Aristotle

Habit formation and procedural learning for AI agents. Part of the [AI Brain Series](https://www.clawhub.ai/skills/hippocampus).

---

## What Is This?

The basal ganglia is the brain structure responsible for **habit formation** — the process by which deliberate, effortful actions become automatic routines. When you first learned to ride a bike, every movement required conscious thought. Now it's effortless. That chunking happened in your basal ganglia.

This skill brings the same mechanism to AI agents:

- **Habits** — Cue → Routine → Reward loops that grow stronger with repetition
- **Procedures** — Multi-step workflows that have been compacted into named routines
- **Suppressions** — Anti-patterns the agent was corrected on and actively avoids
- **Decay** — Unused habits fade; the habit system stays current, not cluttered

---

## Installation

```bash
# Basic install
./install.sh

# Install and set up automatic encoding + decay cron jobs
./install.sh --with-cron

# Process entire conversation history on first encoding (not just last 100 signals)
./install.sh --whole --with-cron
```

---

## Core Workflow

### 1. Encoding (runs on schedule or manually)

```bash
./scripts/encode-pipeline.sh
```

The pipeline scans recent conversation history, extracts habit signals (repeated patterns, explicit instructions, workflow sequences), and updates `memory/habit-state.json`.

### 2. Context Injection (every session)

Add this to your agent's startup prompt or system context:

```bash
# Outputs prose describing active habits and suppressions
./load-habits.sh
```

The agent now knows which patterns are established ("fire automatically") vs forming ("apply deliberately") vs suppressed ("actively avoid").

### 3. Manual Reinforcement

When you notice a good pattern:

```bash
./reinforce-habit.sh --new \
  --cue "User shares a draft for review" \
  --routine "Ask about the intended audience before commenting on style" \
  --reward "Avoids misaligned feedback"
```

When a habit misfires:

```bash
./reinforce-habit.sh --id habit_003 --weaken --note "Wrong context — this was a quick sketch, not a polished draft"
```

### 4. View Current State

```bash
# Full table view (habits + procedures + suppressions)
./get-habits.sh

# Only chunked habits
./get-habits.sh --status chunked

# Only workflow-category items
./get-habits.sh --category workflow

# Raw JSON
./get-habits.sh --json
```

---

## How Strength Works

| Strength | Label | Meaning |
|----------|-------|---------|
| 0.70 – 1.00 | 🟢 chunked | Pattern is automatic — fire on cue |
| 0.40 – 0.69 | 🟡 active | Reliable but still deliberate |
| 0.20 – 0.39 | 🟠 forming | Emerging pattern, needs more repetition |
| 0.00 – 0.19 | ⚪ candidate | Weak signal, may fade |

**Reinforcement formula:** `new = old + (1 - old) × 0.12`  
Each successful execution moves strength 12% of the remaining gap toward 1.0. Habits reach "chunked" status after roughly 10–15 consistent reinforcements from a cold start.

**Decay:** Habits decay 3% per day of inactivity (suppressions decay 0.5% per day — corrections stick).

---

## Brain Dashboard

If hippocampus is installed, basal-ganglia extends the shared brain dashboard with a **🎯 Habits** tab:

```bash
./scripts/generate-dashboard.sh
open ~/.hermes/workspace/brain-dashboard.html
```

---

## Files Written

| File | Purpose |
|------|---------|
| `memory/habit-state.json` | Central store |
| `memory/habit-signals.jsonl` | Preprocessed signals |
| `memory/pending-habits.json` | Signals awaiting LLM classification |
| `memory/brain-events.jsonl` | Append-only event log |
| `BASAL_GANGLIA_STATE.md` | Auto-injected context (chunked habits) |
| `brain-dashboard.html` | Visual dashboard |

---

## Privacy & Security

- All data stays local in `~/.hermes/workspace/`
- `habit-state.json` contains behavioral patterns — add to `.gitignore`
- Suppressions contain correction history — treat as sensitive
- No external network calls

---

## Troubleshooting

**"No habit state found"** — Run `./install.sh` first.

**"No session transcripts found"** — Check `$HOME/.hermes/sessions` exists and contains session files (or run `hermes sessions export --format jsonl <dir>` and point `TRANSCRIPT_DIR` at the export).

**Habits aren't growing** — The encoding pipeline may not be running. Check cron with `hermes cron list` or run manually: `./scripts/encode-pipeline.sh`.

**Dashboard not showing BG tab** — `generate-dashboard.sh` must run after install. It will only add the tab if `habit-state.json` is present.

---

*[AI Brain Series](https://clawhub.ai/ImpKind/basal-ganglia-memory) · Built by ImpKind*
