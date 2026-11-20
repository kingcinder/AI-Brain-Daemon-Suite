## Description: <br>
Procedural precision and smoothness — HOW something is executed, not WHAT to do (that's basal-ganglia-memory's job). Part of the AI Brain series. <br>

This skill is ready for commercial/non-commercial use. <br>

## Publisher: <br>
[ImpKind](https://clawhub.ai/user/ImpKind) <br>

### License/Terms of Use: <br>
MIT <br>


## Use Case: <br>
Developers and agent operators use this skill to give an OpenClaw agent the cerebellum functions described in its SKILL.md, with persistent state under the workspace memory directory. It can set up recurring cron jobs when installed with --with-cron. <br>

### Deployment Geography for Use: <br>
Global <br>

## Known Risks and Mitigations: <br>
Risk: This skill persists state (CEREBELLUM_STATE.md and files under ~/.openclaw/workspace/memory) that can influence future agent behavior. <br>
Mitigation: Review the generated state before relying on it, and edit or delete the state files when the recorded state should not carry forward. <br>
Risk: Background scheduling, if enabled, continues this organ's processing without manual prompts. <br>
Mitigation: Avoid --with-cron unless recurring background processing is intended, and remove the cron jobs when automatic processing is no longer wanted. <br>

## Reference(s): <br>
- [Hippocampus skill](https://www.clawhub.ai/skills/hippocampus) <br>
- [Amygdala Memory skill](https://www.clawhub.ai/skills/amygdala-memory) <br>
- [Vta Memory skill](https://www.clawhub.ai/skills/vta-memory) <br>
- [Basal Ganglia Memory skill](https://www.clawhub.ai/skills/basal-ganglia-memory) <br>
- [Insula Memory skill](https://www.clawhub.ai/skills/insula-memory) <br>
- [Anterior Cingulate Memory skill](https://www.clawhub.ai/skills/anterior-cingulate-memory) <br>
- [Acc Error Memory skill](https://www.clawhub.ai/skills/acc-error-memory) <br>
- [AI Brain Series](https://clawhub.ai/skills?tag=ai-brain) <br>

## Skill Output: <br>
**Output Type(s):** [text, markdown, code, shell commands, configuration, guidance] <br>
**Output Format:** [Markdown guidance, shell commands, JSON state files, and generated HTML dashboard output] <br>
**Output Parameters:** [1D] <br>
**Other Properties Related to Output:** [Writes persistent state under the OpenClaw workspace and can set up recurring cron jobs when installed with --with-cron.] <br>

## Skill Version(s): <br>
1.0.0 (source: openclaw metadata) <br>

## Ethical Considerations: <br>
Users should evaluate whether this skill is appropriate for their environment, review any generated or modified files before relying on them, and apply their organization's safety, security, and compliance requirements before deployment. <br>

<!-- Card created 2026-11-08 during the AI Brain Daemon Suite completeness audit, in the format of the series' existing skill cards, from this package's own SKILL.md and _meta.json. -->
