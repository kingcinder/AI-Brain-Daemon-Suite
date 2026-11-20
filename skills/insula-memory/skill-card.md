## Description: <br>
Interoceptive awareness system for AI agents. Tracks gut signals, cognitive load, friction, somatic comfort, empathic resonance, self-coherence, and context saturation — the felt sense beneath emotion. Part of the AI Brain series. <br>

This skill is ready for commercial/non-commercial use. <br>

## Publisher: <br>
[ImpKind](https://clawhub.ai/user/ImpKind) <br>

### License/Terms of Use: <br>
MIT <br>

## Use Case: <br>
Developers and agent operators use this skill to give an OpenClaw agent persistent interoceptive state — gut-level signals, processing friction, empathic attunement, and identity coherence that carry across sessions and shape how the agent shows up. Unlike the amygdala (which tracks emotional labels), the insula tracks the *felt sense* of what's happening in the agent's processing — the pre-conscious signal that precedes emotional labeling. <br>

### Deployment Geography for Use: <br>
Global <br>

## Known Risks and Mitigations: <br>
Risk: Persistent interoceptive state can influence future agent responses in ways that may not be transparent. <br>
Mitigation: Review INSULA_STATE.md regularly and reset or edit interoceptive-state.json if the encoded state is inaccurate or inappropriate. <br>
Risk: Background cron jobs can continue interoceptive decay and encoding without manual prompts. <br>
Mitigation: Avoid --with-cron unless recurring background processing is desired, and remove insula cron jobs when automatic processing is no longer wanted. <br>
Risk: Recent conversations can be analyzed into persistent interoceptive memory. <br>
Mitigation: Install only when persistent interoceptive awareness is desired, and review or delete INSULA_STATE.md and files under ~/.openclaw/workspace/memory when that state should not carry forward. <br>

## Reference(s): <br>
- [Hippocampus skill](https://www.clawhub.ai/skills/hippocampus) <br>
- [Amygdala Memory skill](https://www.clawhub.ai/skills/amygdala-memory) <br>
- [VTA Memory skill](https://www.clawhub.ai/skills/vta-memory) <br>
- [Basal Ganglia Memory skill](https://www.clawhub.ai/skills/basal-ganglia-memory) <br>
- [Insula Memory skill](https://www.clawhub.ai/skills/insula-memory) <br>
- [Anterior Cingulate Memory skill](https://www.clawhub.ai/skills/anterior-cingulate-memory) <br>
- [ACC Error Memory skill](https://www.clawhub.ai/skills/acc-error-memory) <br>
- [AI Brain Series](https://clawhub.ai/skills?tag=ai-brain) <br>


## Skill Output: <br>
**Output Type(s):** [text, markdown, code, shell commands, configuration, guidance] <br>
**Output Format:** [Markdown guidance, shell commands, JSON state files, JSONL logs, and generated HTML dashboard output] <br>
**Output Parameters:** [1D] <br>
**Other Properties Related to Output:** [Writes persistent interoceptive state under the OpenClaw workspace and can set up recurring cron jobs when installed with --with-cron.] <br>

## Skill Version(s): <br>
0.2.0 <br>

## Ethical Considerations: <br>
Users should evaluate whether this skill is appropriate for their environment, review any generated or modified files before relying on them, and apply their organization's safety, security, and compliance requirements before deployment. The interoceptive state produced by this skill represents a functional analog of internal sensing — not a claim about AI consciousness or sentience. <br>
