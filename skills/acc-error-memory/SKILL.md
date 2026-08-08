---
name: acc-error-memory
description: "Error pattern tracking for AI agents. Detects corrections, escalates recurring mistakes, learns mitigations. Reactive complement to anterior-cingulate-memory. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🔴"
    tags: ["memory", "monitoring", "ai-brain", "error-detection"]
  openclaw:
    emoji: "🔴"
    version: "1.0.0"
    author: "ImpKind"
    repo: "https://github.com/ImpKind/acc-error-memory"
    requires:
      os: ["darwin", "linux"]
      bins: ["python3", "jq"]
    tags: ["memory", "monitoring", "ai-brain", "error-detection"]
---

# ACC Error Memory 🔴

**Reactive error pattern tracking for AI agents.** Part of the AI Brain series.

The ACC Error module watches the *past* — scanning corrections the user made, detecting recurring mistake patterns, and surfacing mitigations at session start so history doesn't repeat. Its proactive partner, `anterior-cingulate-memory` ⚡, watches the *present* for emerging conflicts and uncertainty.

## When to Use

Use this skill when:
- The user corrects you ("no", "wrong", "actually…") and you want to learn from it instead of repeating it
- A mistake has happened more than once and should be escalated into a tracked pattern
- You want session-start awareness of your known failure modes (load `ACC_STATE.md` via `load-state.sh`)
- You're integrating with the AI Brain Suite and want a reactive feedback loop paired with `anterior-cingulate-memory`

Not for: live conflict detection (that's `anterior-cingulate-memory`), or one-off mistakes you don't expect to recur.

## The Problem

AI agents make mistakes:
- Misunderstand user intent
- Give wrong information
- Use the wrong tone
- Miss context from earlier in conversation

Without tracking, the same mistakes repeat. This skill detects and logs error patterns, building awareness that persists across sessions.

## The Solution

Track error patterns with:
- **Pattern detection** — recurring error types get escalated
- **Severity levels** — normal (1×), warning (2×), critical (3+)
- **Resolution tracking** — patterns clear after 30+ days without recurrence
- **Watermark system** — incremental processing, no re-analysis

## Configuration

### ACC_MODELS (Model Agnostic)

The LLM screening and calibration scripts are model-agnostic. Set `ACC_MODELS` to use any CLI-accessible model:

```bash
# Default (Anthropic Claude via CLI)
export ACC_MODELS="claude --model haiku -p,claude --model sonnet -p"

# Ollama (local)
export ACC_MODELS="ollama run llama3,ollama run mistral"

# OpenAI
export ACC_MODELS="openai chat -m gpt-4o-mini,openai chat -m gpt-4o"

# Single model (no fallback)
export ACC_MODELS="claude --model haiku -p"
```

**Format:** Comma-separated CLI commands. Each command is invoked with the prompt appended as the final argument. Models are tried in order — if the first fails or times out (45s), the next is used as fallback.

**Scripts that use ACC_MODELS:**
- `haiku-screen.sh` — LLM confirmation of regex-filtered error candidates
- `calibrate-patterns.sh` — Pattern calibration via LLM classification

## Quick Start

### 1. Install

```bash
cd ~/.hermes/workspace/skills/acc-error-memory
./install.sh --with-cron
```

This will:
- Create `memory/acc-state.json` with empty patterns
- Generate `ACC_STATE.md` for session context
- Set up cron for analysis 3× daily (4 AM, 12 PM, 8 PM)

### 2. Check current state

```bash
./scripts/load-state.sh
# 🔴 ACC Error State Loaded:
# Active patterns: 2
# - tone_mismatch: 2x (warning)
# - missed_context: 1x (normal)
```

### 3. Manual error logging

```bash
./scripts/log-error.sh \
  --pattern "factual_error" \
  --context "Stated Python 3.9 was latest when it's 3.12" \
  --mitigation "Always web search for version numbers"
```

### 4. Check for resolved patterns

```bash
./scripts/resolve-check.sh
# Checks patterns not seen in 30+ days
```

## Scripts

| Script | Purpose |
|--------|---------|
| `preprocess-errors.sh` | Extract user+assistant exchanges since watermark |
| `encode-pipeline.sh` | Run full preprocessing pipeline |
| `haiku-screen.sh` | LLM screen of regex-flagged exchange candidates |
| `calibrate-patterns.sh` | LLM-based pattern calibration |
| `log-error.sh` | Log an error with pattern, context, mitigation |
| `load-state.sh` | Human-readable state for session context |
| `resolve-check.sh` | Check for patterns ready to resolve (30+ days) |
| `update-watermark.sh` | Update processing watermark |
| `sync-state.sh` | Generate ACC_STATE.md from acc-state.json |
| `log-event.sh` | Log events to brain-events.jsonl (type: `acc-error`) |
| `analyze-day.sh` | Daily summary of error activity |
| `quick-check.sh` | Fast pattern scan without full pipeline |
| `prefilter-exchanges.sh` | Pre-filter before LLM screening |
| `get-lessons.sh` | Retrieve active mitigations for session context |

## How It Works

### 1. Preprocessing Pipeline

The `encode-pipeline.sh` extracts exchanges from session transcripts:

```bash
./scripts/encode-pipeline.sh --no-spawn
# 🔴 ACC Error Encode Pipeline
# Step 1: Extracting exchanges...
# Found 47 exchanges to analyze
```

Output: `pending-errors.json` with user+assistant pairs:
```json
[
  {
    "assistant_text": "The latest Python version is 3.9",
    "user_text": "Actually it's 3.12 now",
    "timestamp": "2026-02-11T10:00:00Z"
  }
]
```

### 2. Error Analysis (via Cron Agent)

An LLM (configured via `ACC_MODELS`) analyzes each exchange for:
- Direct corrections ("no", "wrong", "that's not right")
- Implicit corrections ("actually...", "I meant...")
- Frustration signals ("you're not understanding")
- User confusion caused by the agent

### 3. Pattern Tracking

Errors are logged with pattern names:
```bash
./scripts/log-error.sh --pattern "factual_error" --context "..." --mitigation "..."
```

Patterns escalate with repetition:
- **1×** → normal (noted)
- **2×** → warning (watch for this)
- **3+** → critical (actively avoid!)

### 4. Resolution

Patterns not seen for 30+ days move to resolved:
```bash
./scripts/resolve-check.sh
# ✓ Resolved: version_numbers (32 days clear)
```

## Cron Schedule

Default: 3× daily for a faster feedback loop. Offset from other suite crons to avoid simultaneous sub-agent spawns.

```bash
# Add to cron (or use ./install.sh --with-cron)
hermes cron create "0 4,12,20 * * *" "Run ACC error analysis pipeline and report any new or resolved patterns" --name acc-error-analysis
```

## Brain Dashboard

The ACC Error and ACC Conflict modules share the **⚡ Oversight** tab in the unified Brain Dashboard:

```bash
./scripts/generate-dashboard.sh
open ~/.hermes/workspace/brain-dashboard.html
```

The Oversight tab shows:
- Active error patterns with severity levels
- Active conflicts with load meter
- Combined correction/conflict timeline
- Mitigations currently in effect

The dashboard regenerates on every cron analysis run.

### After Installation (for agents)

When you install this skill, **notify the user** about the dashboard:

> 🔴 **ACC Error Memory installed!**
>
> Error patterns and corrections are now tracked. View them in the Brain Dashboard:
> `~/.hermes/workspace/brain-dashboard.html`

## Auto-Injection (Zero Manual Steps!)

After install, `ACC_STATE.md` is created in your workspace root.

OpenClaw automatically injects all `*.md` files from workspace into session context:

1. **New session starts**
2. **ACC_STATE.md is auto-loaded**
3. **Agent sees current error patterns**
4. **Behavior adjusted to avoid known mistake types**

## State File Format

```json
{
  "version": "2.0",
  "lastUpdated": "2026-02-11T12:00:00Z",
  "activePatterns": {
    "factual_error": {
      "count": 3,
      "severity": "critical",
      "firstSeen": "2026-02-01T10:00:00Z",
      "lastSeen": "2026-02-10T15:00:00Z",
      "context": "Stated outdated version numbers",
      "mitigation": "Always verify versions with web search"
    }
  },
  "resolved": {
    "tone_mismatch": {
      "count": 2,
      "resolvedAt": "2026-02-11T04:00:00Z",
      "daysClear": 32
    }
  },
  "stats": {
    "totalErrorsLogged": 15
  }
}
```

## Behavior Guidelines

When you see patterns in ACC_STATE.md:
- 🔴 **Critical (3+)** — actively verify before responding in this area
- ⚠️ **Warning (2×)** — be extra careful; note uncertainty
- ✅ **Resolved** — lesson learned, maintain vigilance anyway

## Event Logging

Track ACC error activity over time. All events use `"type": "acc-error"` to distinguish from the `"acc-conflict"` events written by `anterior-cingulate-memory`.

```bash
./scripts/log-event.sh analysis errors_found=2 patterns_active=3 patterns_resolved=1
./scripts/log-event.sh pattern_escalated pattern=factual_error severity=critical
./scripts/log-event.sh pattern_resolved pattern=tone_mismatch days_clear=32
```

Events append to `~/.hermes/workspace/memory/brain-events.jsonl`:
```json
{"ts":"2026-02-11T12:00:00Z","type":"acc-error","event":"analysis","errors_found":2,"patterns_active":3}
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

## AI Brain Suite Integration

ACC Error is the feedback loop that keeps the rest of the suite honest. Errors don't just sit in isolation — they ripple:

| Trigger | Signal to Send |
|---------|---------------|
| Critical pattern logged (3+) | `amygdala/scripts/update-state.sh --emotion frustration --intensity 0.4 --trigger "critical error pattern: <pattern>"` |
| Pattern resolved | `amygdala/scripts/update-state.sh --emotion satisfaction --intensity 0.5 --trigger "error pattern resolved: <pattern>"` |
| Recurring error pattern (3+) | `basal-ganglia/reinforce-habit.sh --suppress "<pattern>" --reason "<mitigation>" --strength 0.7` (auto-create suppression) |
| Critical patterns active | `insula/scripts/update-state.sh --signal vigilance --intensity 0.6 --source "critical error patterns active"` |
| Clean analysis (0 new errors) | `vta/scripts/log-reward.sh --type competence --intensity 0.3 --source "clean ACC error analysis run"` |

See `BRAIN_SUITE.md` for the complete cross-module signal map.

## Complement: anterior-cingulate-memory

This skill tracks **reactive error patterns** — learning from user corrections *after the fact*.
`anterior-cingulate-memory` ⚡ tracks **proactive conflict detection** — noticing problems *as they emerge*.

Install both for complete cognitive oversight:

```bash
./install.sh --with-cron  # This skill: reactive error tracking
# Plus:
cd ~/.hermes/workspace/skills/anterior-cingulate-memory && ./install.sh --with-cron
```

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| ⭐ [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| 🎯 [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| 🌡️ [insula-memory](https://www.clawhub.ai/skills/insula-memory) | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 **acc-error-memory** | Error pattern tracking and correction learning | ✅ Live |

## Philosophy

The ACC in the human brain creates that "something's off" feeling — the pre-conscious awareness that you've made an error. This skill gives AI agents a similar capability: persistent awareness of mistake patterns that influences future behavior.

Mistakes aren't failures. They're data. The ACC turns that data into learning.

---

*Built with 🔴 by the OpenClaw community*
