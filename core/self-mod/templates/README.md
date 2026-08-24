# Proposal Templates for Self-Mod LLM Generator
# Each template is a fill-in pattern the model can use instead of inventing
# changes from scratch. Reduces hallucination and ensures common patterns
# are applied consistently.

## Template: Add Decaying Metric
**When:** A skill should track a value that decays over time (drive, arousal, etc.)
**Pattern:**
```bash
# Add to sync-state.sh: include the metric in the JSON output
# Add to decay script: multiply by DECAY_RATE each cycle
# Add to generate-dashboard.sh: show the metric with trend arrow
```

## Template: Add LLM-Summarized Signal
**When:** A skill should use LLM to summarize or classify incoming signals
**Pattern:**
```bash
# Add to encode-pipeline.sh: read pending signals, call llm-call.sh for summary
# Update the skill's state file with summarized results
# Add to generate-dashboard.sh: show summarized signal count
```

## Template: Add Cross-Skill Signal Route
**When:** One skill's output should feed into another skill's input
**Pattern:**
```bash
# Add route entry to thalamus-memory/scripts/route-signals.sh
# Add signal consumer in the target skill's encode-pipeline.sh
# Test with: echo '{"event":"test_signal","source":"skill_a"}' >> ~/.hermes/workspace/memory/brain-signals.jsonl
```

## Template: Add Dashboard Fragment
**When:** A skill should show its state in the brain dashboard
**Pattern:**
```bash
# Add/update generate-dashboard.sh to output the skill's fragment
# Register the fragment in core/signaling/dashboard-fragments/
# Verify with: bash tests/test_dashboard_learning_signals.sh
```

## Template: Fix Unbound Variable
**When:** A script crashes with "unbound variable" under set -u
**Pattern:**
```bash
# Change: [ "$VAR" = "value" ]
# To:     [ "${VAR:-}" = "value" ]
# Or:     VAR="${VAR:-default_value}"
```

## Template: Add Timeout to LLM Call
**When:** A script calls llm-call.sh and needs a timeout
**Pattern:**
```bash
# Set LLM_TIMEOUT env var before calling llm-call.sh
# Example: LLM_TIMEOUT=30 bash llm-call.sh --system "..." --user "..."
```
