---
name: thalamus-memory
description: "Centralized attentional gating and signal routing for the AI Brain Suite. The thalamus receives signals from all brain skills and selectively amplifies or suppresses them based on current goals, executive load, and attentional priorities — like the thalamic reticular nucleus directing the brain's searchlight of attention. Part of the AI Brain series."
metadata:
  hermes:
    emoji: "🚦"
    tags: ["memory", "attention", "signaling", "ai-brain", "integration"]
  openclaw:
    emoji: "🚦"
    version: "1.1.0"
    author: "Brain Suite Core"
    requires:
      os: ["darwin", "linux"]
      bins: ["python3", "jq"]
    tags: ["memory", "attention", "signaling", "ai-brain", "integration"]
---

# Thalamus — Attentional Gating & Signal Routing 🚦

**The brain's searchlight of attention.** Part of the AI Brain series.

The thalamus is the brain's central relay station — but it's not a passive relay. The thalamic reticular nucleus (TRN) actively gates signals: amplifying what matters *right now* and suppressing what doesn't. This skill brings that same mechanism to the AI Brain Suite: instead of skills directly calling each other's scripts in fragile, invisible chains, all cross-module signals pass through the thalamus for context-aware routing.

## When to Use

Use this skill when:
- You want cross-module signals to actually fire automatically, not just be documented in SKILL.md tables
- You want the brain suite to have a unified attention mechanism that respects current goals, executive load, and circadian phase
- You want to avoid the "ad-hoc signal spaghetti" where skill A calling skill B's script breaks when B isn't installed
- You're integrating a new skill and want it to receive relevant signals from the rest of the suite

Not for: direct state-file reads (skills read their own state), or internal computation within a single skill.

## The Problem

Every existing skill's SKILL.md documents cross-module signal maps:

> "When Amygdala detects joy → call VTA's log-reward.sh"
> "When ACC-Error sees a recurring pattern → call Basal Ganglia's reinforce-habit.sh"

But these are **documentation, not code.** No automated mechanism routes these signals. Skills are islands with documented bridges that were never built. The result: the brain suite has 13 regions with rich internal state but no systematic integration between them. The "connectome" exists only on paper.

## The Solution

The thalamus provides three things:

1. **Signal Bus** (`core/signaling/`) — A pub/sub infrastructure where skills publish events and subscribe to what they care about, instead of calling each other directly.
2. **Attentional Gate** (`gate.sh`) — A relevance filter that scores every incoming signal against current goals, executive load, and circadian phase. High-relevance signals are amplified; low-relevance ones are suppressed or deferred.
3. **Routing Table** (`core/signaling/route-signals.sh`) — The canonical, machine-readable version of every cross-module signal path. One file to update when adding signal wiring, instead of hunting through 13 SKILL.md files.

## Neuroscience Basis

The human thalamus, particularly the **thalamic reticular nucleus (TRN)** , is a sheet of inhibitory neurons wrapped around the thalamus that selectively gates signals between thalamus and cortex. Francis Crick's "searchlight hypothesis" (1984, *PNAS*) proposed that the TRN directs the "searchlight of attention" by amplifying relevant signals and suppressing irrelevant ones.

Key properties this skill maps:
- **Sensory gating** — Filtering signals by relevance before they reach "cortical" (skill) processing
- **Attentional set** — Maintaining a current attentional priority based on goals and context
- **Arousal modulation** — Adjusting gate sensitivity based on circadian phase (more permissive during active hours, more restrictive during winding-down)
- **Cross-modal binding** — Routing related signals from different sources to the same target when they co-occur

### The bidirectional relay (cortico-thalamo-cortical loop)

Since 1.1.0 the gate is a **bidirectional relay**, not a one-way filter. The loop has two legs, mirroring the anatomy:

- **Feedforward (driving) path** — sensory signals score and dispatch to cortical target skills (`--process` / `--stdin`). Every dispatch is tallied in `relay.stats.feedforward` with a `lastLoopAt` timestamp, so the driving path is observable.
- **Feedback (modulatory) path** — cortical skills issue `--feedback attend <target>` directives that (a) add the target to `attentionFocus` (so the existing in-focus sharpening engages) and (b) record a per-channel gain. A subsequent signal whose source or name matches an attend target is amplified by `(1.0 + 0.5×weight)` — the layer-6 / TRN top-down bias that makes attended channels pass more easily. `--feedback release <target>` stands the loop down, restoring the baseline gain. No active directives → gain is exactly 1.0 → byte-identical to a pre-relay run (neutral-by-default).

This is the attention-searchlight loop proper: cortex modulates the gate, and the gate regulates what cortex receives. **Key citations:** Crick (1984) *PNAS* (searchlight hypothesis); Sherman & Guillery (2006) *Exploring the Thalamus and Its Role in Cortical Function* (layer-6 feedback drives); Halassa & Kastner (2017) *Nature Neuroscience*; McAlonan et al. (2008) *Nature Neuroscience*

## Quick Start

```bash
cd ~/.hermes/workspace/skills/thalamus-memory
./install.sh --with-cron

# Check current attention state
./scripts/gate.sh --status

# Manually publish a signal to test the bus
core/signaling/publish.sh --type "emotional" --source "amygdala-memory" \
  --signal "positive_state" --intensity 0.7

# Process pending signals through the gate
./scripts/gate.sh --process
```

## Architecture

```
  Skill A ──publish.sh──→ brain-signals.jsonl ──→ signal-daemon.sh
                                                       │
  Skill B ──publish.sh──→ brain-signals.jsonl          │
                                                       ▼
  Skill C ──publish.sh──→ brain-signals.jsonl ──→ thalamus/gate.sh
                                                       │
                                              ┌────────┼────────┐
                                              │  attention filter │
                                              │  (goals, load,   │
                                              │   circadian)      │
                                              └────────┼────────┘
                                                       │
                                              ┌────────▼────────┐
                                              │ route-signals.sh │
                                              │  (dispatch to    │
                                              │   target skills) │
                                              └─────────────────┘
```

## Bidirectional Relay (Cortico-Thalamo-Cortical Loop)

Cortical skills modulate the gate through a dedicated feedback channel (not the sensory signal bus — mirroring the anatomy, where corticothalamic feedback is a direct pathway, not sensory re-entry):

```bash
# Cortex (e.g. PFC after committing to a goal) tells the gate to amplify
# everything related to error correction:
./scripts/gate.sh --feedback attend error_correction --weight 0.8 --from prefrontal-cortex-memory

# The attended channel now scores ×(1.0 + 0.5·0.8) = ×1.4 on matching signals.

# Cortex stands attention down when the task completes:
./scripts/gate.sh --feedback release error_correction

# Observe the loop (feedforward dispatches + feedback directives):
./scripts/gate.sh --status
```

The target may be a source skill name (`amygdala-memory`), a signal name (`positive_state`), or goal text. Matching is literal substring, case-insensitive, consistent with the in-focus check. Weights are clamped to [0,1]; defaults to 0.6. Every directive is recorded with provenance (`from`) and timestamp, and `relay.history` keeps the last 10 directives.

## Gate Dimensions

The attention gate scores every incoming signal on five dimensions:

| Dimension | Range | What It Measures |
|-----------|-------|------------------|
| **goalRelevance** | 0.0–1.0 | Does this signal relate to any active PFC goal? |
| **noveltyBonus** | 0.0–1.0 | Is this a new signal type, or a familiar pattern? |
| **urgency** | 0.0–1.0 | From the signal's intensity and source priority |
| **loadHeadroom** | 0.0–1.0 | Inverse of executive load — high load = low headroom |
| **circadianGain** | 0.5–1.5 | Multiplier: 1.5 during active hours, 0.5 during sleep |

**Gate score = (goalRelevance × 0.35 + noveltyBonus × 0.15 + urgency × 0.25 + loadHeadroom × 0.25) × circadianGain**

| Score | Action |
|-------|--------|
| ≥ 0.70 | **Amplify** — route at full intensity, boost signal strength |
| 0.40–0.70 | **Pass** — route at original intensity |
| 0.20–0.40 | **Attenuate** — route at reduced intensity (×0.5) |
| < 0.20 | **Suppress** — defer to pending queue, re-evaluate next cycle |

## State File Format

```json
{
  "version": "1.0",
  "lastUpdated": "2026-08-04T12:00:00Z",
  "attentionFocus": ["goal_shipping", "error_correction"],
  "suppressedQueue": [
    {
      "signal": {"source": "amygdala-memory", "signal": "positive_state"},
      "suppressedAt": "2026-08-04T11:00:00Z",
      "retryAfter": "2026-08-04T12:00:00Z",
      "reason": "low goal relevance during active error correction"
    }
  ],
  "stats": {
    "totalSignalsProcessed": 47,
    "amplified": 12,
    "passed": 22,
    "attenuated": 8,
    "suppressed": 5,
    "dispatchedToTargets": 42
  },
  "gateSensitivity": 0.5,
  "lastGateRun": "2026-08-04T11:30:00Z",
  "relay": {
    "feedback": [
      {"kind": "attend", "target": "error_correction", "weight": 0.8,
       "from": "prefrontal-cortex-memory", "issuedAt": "2026-08-04T11:35:00Z"}
    ],
    "history": [],
    "stats": {"feedforward": 12, "feedback": 2, "lastLoopAt": "2026-08-04T11:35:00Z"}
  }
}
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/gate.sh` | Main attention gate — scores, filters, dispatches signals, and runs the bidirectional relay (`--feedback attend|release <target> [--weight <0-1>] [--from <skill>]`) |
| `scripts/attention-filter.sh` | Compute the five-dimensional relevance score for a signal |
| `scripts/sync-state.sh` | Regenerate THALAMUS_STATE.md and dashboard fragment |
| `scripts/decay.sh` | Release suppressed signals that have aged past their retry window |
| `scripts/log-event.sh` | Append to brain-events.jsonl (type: `thalamus`) |

## Integration with the Signal Bus

Skills publish via the shared `publish.sh`:

```bash
# In any skill script, instead of:
#   ~/.hermes/workspace/skills/vta-memory/scripts/log-reward.sh --type social ...
#
# Publish a signal:
core/signaling/publish.sh \
  --type "emotional" \
  --source "amygdala-memory" \
  --signal "positive_state" \
  --intensity 0.7 \
  --payload '{"emotion":"joy","trigger":"completed project"}'
```

The thalamus (via `signal-daemon.sh` and `gate.sh`) picks it up, scores it, and if it passes the gate, dispatches it to every target skill registered in `route-signals.sh`.

## AI Brain Suite Integration

The thalamus is the **integration hub** — it doesn't generate its own signals, it routes everyone else's. It consumes the signal bus and produces directed, gated dispatches to target skills.

### Add to session startup (AGENTS.md)

```markdown
## Every Session
1. 🧠 Load memories: `~/.hermes/workspace/skills/hippocampus/scripts/load-core.sh`
2. 🎭 Load emotional state: `~/.hermes/workspace/skills/amygdala-memory/scripts/load-emotion.sh`
3. ⭐ Load motivation: `~/.hermes/workspace/skills/vta-memory/scripts/load-motivation.sh`
4. 🎯 Load habits: `~/.hermes/workspace/skills/basal-ganglia-memory/load-habits.sh`
5. 🌡️ Load felt sense: `~/.hermes/workspace/skills/insula-memory/scripts/load-sense.sh`
6. ⚡ Load conflict state: `~/.hermes/workspace/skills/anterior-cingulate-memory/scripts/load-state.sh`
7. 🔴 Load error patterns: `~/.hermes/workspace/skills/acc-error-memory/scripts/load-state.sh`
8. 🚦 Load attention state: `~/.hermes/workspace/skills/thalamus-memory/scripts/gate.sh --status`
```

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| 🧠 hippocampus | Memory formation, decay, reinforcement | ✅ Live |
| 🎭 amygdala-memory | Emotional state tracking | ✅ Live |
| ⭐ vta-memory | Reward and motivation | ✅ Live |
| 🎯 basal-ganglia-memory | Habit formation and procedural learning | ✅ Live |
| 🌡️ insula-memory | Interoceptive awareness and gut sense | ✅ Live |
| ⚡ anterior-cingulate-memory | Conflict detection and uncertainty monitoring | ✅ Live |
| 🔴 acc-error-memory | Error pattern tracking and correction learning | ✅ Live |
| 🧭 prefrontal-cortex-memory | Executive function: goals, arbitration | ✅ Live |
| 💓 heartbeat-memory | Autonomous initiative timer | ✅ Live |
| 🎚️ cerebellum-memory | Procedural precision calibration | ✅ Live |
| 🫂 social-memory | Relationships and theory of mind | ✅ Live |
| 🚦 **thalamus-memory** | Attentional gating and signal routing | ✅ Live |

## Philosophy

In the brain, the thalamus doesn't think. It doesn't feel. It doesn't decide what to do. But without it, the cortex is isolated — regions that should be communicating fire in silence, each unaware of the others.

The Suite already has rich, neurologically-grounded modules for memory, emotion, motivation, habits, and decision-making. What it hasn't had is the tissue that connects them. The thalamus is that tissue — not another "smart" module, but the infrastructure that makes every other module smarter by letting them actually talk to each other.

> *"The thalamus is not a relay. It's a gate. And attention is what opens it."*

---

*Built with 🚦 as part of the AI Brain Suite core*
