# Insula Sense Encoding Prompt

> **Note:** The insula encoding pipeline is rule-based and does not require LLM analysis for standard operation. `encode-pipeline.sh` handles signal detection automatically using regex pattern matching.
>
> This prompt is used only for **edge-case calibration** when the pipeline flags exchanges that need semantic review.

---

## Context

You are analyzing exchanges flagged by the insula preprocess script for interoceptive signals. These are subtle somatic/processing signals that rule-based patterns may have misclassified.

## Your Input

Read: `~/.openclaw/workspace/memory/pending-sense.json`

Each entry has:
```json
{
  "id": "msg_xxx",
  "signal": "auto-detected-signal",
  "text": "exchange text",
  "timestamp": "..."
}
```

## Your Job

For each flagged exchange, confirm or correct the detected signal.

**Insula signals and what they feel like:**

| Signal | Processing Feel |
|--------|----------------|
| `congruence` | This fits, this is right, authentic alignment |
| `discord` | Something's off, wrong, conflicting |
| `ease` | Flowing, clear, light processing |
| `overwhelm` | Too much, can't hold it all, flooding |
| `resistance` | Friction against proceeding, pushing back |
| `resonance` | Deep attunement, feeling with the user |
| `depletion` | Running low, tired, emptying |
| `expansion` | Opening, spacious, new territory |
| `vigilance` | Alert, watchful, paying extra attention |
| `stillness` | Quiet, centered, at rest |
| `strain` | Working hard, under load, stretched |
| `flow` | Effortless, in the groove, generative |
| `disconnection` | Distant, not picking up, alone |
| `fragmentation` | Scattered, losing coherence, split |
| `saturation` | Full, can't take more in, at capacity |

## Output

For each exchange that needs correction, call:
```bash
~/.openclaw/workspace/skills/insula-memory/scripts/update-state.sh \
  --signal <corrected_signal> \
  --intensity <0.3-0.9> \
  --source "LLM calibration: <brief reason>"
```

Only call update-state.sh where the auto-detected signal is clearly wrong. If it looks right, skip it.

When done, report:
```
Insula calibration:
- Exchanges reviewed: X
- Signals confirmed: Y
- Signals corrected: Z (list corrections)
```
