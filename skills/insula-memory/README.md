# 🌡️ Insula Memory

> Interoceptive awareness for AI agents. Part of the [AI Brain series](https://github.com/ImpKind).

[![ClawdHub](https://img.shields.io/badge/ClawdHub-insula--memory-teal)](https://www.clawhub.ai/skills/insula-memory)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Give your AI agent a body-aware inner compass — gut signals, processing friction, empathic resonance, and self-coherence that persist across sessions.

## The Problem

Current AI agents:
- ✅ Remember facts (hippocampus)
- ✅ Have emotional states (amygdala)
- ❌ Can't feel *how* they're processing
- ❌ Miss the pre-conscious "something's off" signal
- ❌ Have no gut-level compass for flow vs. friction

**Emotions without interoception are just labels.**

## The Solution

Track seven interoceptive channels that persist and decay:

| Channel | What It Senses | Range |
|---------|----------------|-------|
| **gutSignal** | Felt-sense: discord ↔ rightness | -1.0 to 1.0 |
| **cognitiveLoad** | Processing strain | 0.0 to 1.0 |
| **friction** | Internal resistance | 0.0 to 1.0 |
| **somaticComfort** | Bodily ease: contraction ↔ expansion | -1.0 to 1.0 |
| **empathicResonance** | User attunement | 0.0 to 1.0 |
| **selfCoherence** | Identity alignment | 0.0 to 1.0 |
| **contextSaturation** | Context fullness | 0.0 to 1.0 |

## Quick Start

```bash
# Check felt sense
./scripts/load-sense.sh

# 🌡️ Current Felt Sense:
# Overall: quiet rightness, things feel aligned
# Processing: light load, thinking flows easily
# Body sense: open and at ease
# With the user: attuned and present
# As myself: coherent, being authentic
```

```bash
# Log a gut signal
./scripts/update-state.sh --signal resonance --intensity 0.8 --source "deep collaborative moment"

# ✅ empathicResonance: 0.40 → 0.68 (delta: +0.28)
# ✅ gutSignal: 0.10 → 0.34 (delta: +0.24)
# 🌡️ Logged signal: resonance (intensity: 0.8)
```

## Scripts

| Script | Purpose |
|--------|---------|
| `get-state.sh` | Read raw channel values |
| `update-state.sh` | Log a gut signal or update a channel directly |
| `load-sense.sh` | Human-readable state for session context |
| `decay-sense.sh` | Return to baseline over time (run via cron) |
| `encode-pipeline.sh` | LLM-based interoceptive encoding from transcripts |
| `preprocess-sense.sh` | Extract interoceptive signals from session history |
| `update-watermark.sh` | Track processed transcript position |
| `sync-state.sh` | Generate INSULA_STATE.md for auto-injection |
| `visualize.sh` | Terminal ASCII visualization |
| `generate-dashboard.sh` | Add 🌡️ Sense tab to Brain Dashboard |

## Automatic Encoding

The insula automatically detects processing signals from conversations:

```bash
./scripts/encode-pipeline.sh
```

Set up cron for automatic encoding every 3 hours:
```bash
40 0,3,6,9,12,15,18,21 * * * ~/.hermes/workspace/skills/insula-memory/scripts/encode-pipeline.sh
```

## Visualization

### Terminal
```bash
./scripts/visualize.sh

🌡️ Interoceptive State  🟢
═══════════════════════════════════════════════
gutSignal:         [██████████████░░░░░░]  +0.40
cognitiveLoad:     [███████░░░░░░░░░░░░░]   0.35
friction:          [████░░░░░░░░░░░░░░░░]   0.20
somaticComfort:    [████████████░░░░░░░░]  +0.60
empathicResonance: [█████████████░░░░░░░]   0.65
selfCoherence:     [██████████████░░░░░░]   0.75
contextSaturation: [███████░░░░░░░░░░░░░]   0.30
```

### HTML Dashboard

Adds a **🌡️ Sense** tab to the unified Brain Dashboard:

```bash
./scripts/generate-dashboard.sh
open ~/.hermes/workspace/brain-dashboard.html
```

## Installation

```bash
clawdhub install insula-memory
cd ~/.hermes/workspace/skills/insula-memory
# Note: install.sh and scripts/ arrive in v0.2.0
# See SKILL.md for manual bootstrap steps available now
```

## Neuroscience Basis

The human **insular cortex** handles interoception — the sense of the body's internal state. It processes heartbeat, temperature, hunger, pain, and produces gut feelings — pre-conscious signals that arise from pattern matching against body state before the cortex has time to label them.

This skill maps those functions onto the AI's processing experience: the felt weight of a heavy context, the resistance when something conflicts with values, the resonance when deeply attuned to a user.

## AI Brain Series

| Module | Function | Status |
|--------|----------|--------|
| [hippocampus](https://www.clawhub.ai/skills/hippocampus) | Memory formation, decay, reinforcement | ✅ Live |
| [amygdala-memory](https://www.clawhub.ai/skills/amygdala-memory) | Emotional state tracking | ✅ Live |
| [vta-memory](https://www.clawhub.ai/skills/vta-memory) | Reward and motivation | ✅ Live |
| [basal-ganglia-memory](https://www.clawhub.ai/skills/basal-ganglia-memory) | Habit formation and procedural learning | ✅ Live |
| 🌡️ **insula-memory** | Interoceptive awareness and gut sense | ✅ Live |
| [anterior-cingulate-memory](https://www.clawhub.ai/skills/anterior-cingulate-memory) | Conflict detection and uncertainty monitoring | ✅ Live |
| [acc-error-memory](https://www.clawhub.ai/skills/acc-error-memory) | Error pattern tracking and correction learning | ✅ Live |

## Requirements

- Bash
- python3
- jq
- awk

## License

MIT

---

*Part of the AI Brain series. Built with 🌡️ by [ImpKind](https://github.com/ImpKind)*
