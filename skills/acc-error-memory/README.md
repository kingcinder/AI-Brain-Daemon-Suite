# ACC Error Memory 🔴

> Error pattern tracking for AI agents — the "something's off" detector

Part of the [AI Brain series](https://clawhub.ai/skills?tag=ai-brain) — giving AI agents human-like cognitive components.

## What It Does

Track errors and learn from mistakes:

- **Detects** when users correct or express frustration
- **Logs** error patterns with context and mitigations
- **Escalates** recurring patterns (normal → warning → critical)
- **Resolves** patterns that haven't recurred in 30+ days

## Quick Install

```bash
clawhub install acc-error-memory
cd ~/.openclaw/workspace/skills/acc-error-memory
./install.sh --with-cron
```

## How It Works

1. **Preprocessing** — Extracts user+assistant exchanges from transcripts
2. **Analysis** — LLM detects corrections, frustration, confusion
3. **Logging** — Errors logged with pattern names
4. **Tracking** — Patterns escalate with repetition

```
Exchange: "The latest Python is 3.9" → "Actually it's 3.12"
         ↓
Pattern: factual_error (now at 2x = warning)
         ↓
Mitigation: "Always verify versions with web search"
```

## At Session Start

Load ACC state to see what to watch for:

```bash
./scripts/load-state.sh

# ⚡ ACC State:
# 🔴 factual_error: 3x (critical) — verify before stating facts
# ⚠️ tone_mismatch: 2x (warning) — match user's emotional state
# ✅ missed_context: resolved 32 days ago
```

## Complement to anterior-cingulate-memory

These two skills cover different aspects of the ACC:

| Skill | Focus | Timing |
|-------|-------|--------|
| **acc-error-memory** | Reactive error pattern tracking | Post-correction learning |
| **anterior-cingulate-memory** | Proactive conflict detection | Real-time / in session |

**Which one logs a given signal?** This skill only logs a signal once the
user has actually corrected the agent — a confirmed mistake, after the
fact. If the agent instead notices a conflict, ambiguity, or rising
uncertainty *before* committing to an action or answer, that belongs to
`anterior-cingulate-memory` instead, not here. The same underlying issue
can legitimately show up in both: `anterior-cingulate-memory` recording the
flagged uncertainty in the moment, this skill recording the confirmed
error afterward if that uncertainty turned out to be founded. That pairing
is itself useful calibration signal, not duplicate logging.

Install both for complete anterior cingulate coverage.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| [hippocampus](https://clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| [amygdala-memory](https://clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| [vta-memory](https://clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| [basal-ganglia-memory](https://clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| [insula-memory](https://clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| [anterior-cingulate-memory](https://clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 **acc-error-memory** | Error pattern tracking and correction learning | ✅ Live |

## License

MIT
