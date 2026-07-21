## Description: <br>
Persistent memory system for AI agents. Automatic encoding, decay, and semantic reinforcement - just like the hippocampus in your brain. Based on Stanford Generative Agents (Park et al., 2023). <br>

This skill is ready for commercial/non-commercial use. <br>

## Publisher: <br>
[ImpKind](https://clawhub.ai/user/ImpKind) <br>

### License/Terms of Use: <br>
MIT <br>


## Use Case: <br>
Developers and OpenClaw agent users use this skill to create persistent long-term memory from agent conversations, including indexed memories, recall output, decay, reinforcement, and session-start context. <br>

### Deployment Geography for Use: <br>
Global <br>

## Known Risks and Mitigations: <br>
Risk: The skill can persistently scan conversation history and store sensitive personal memories. <br>
Mitigation: Install only when long-lived agent memory is intended, review the generated memory files, and periodically delete unneeded data under ~/.openclaw/workspace/memory/ and HIPPOCAMPUS_CORE.md. <br>
Risk: The --whole option can ingest historical conversation data beyond recent context. <br>
Mitigation: Start with the default recent-signal setup or a small --signals value, and use --whole only after confirming historical ingestion is desired. <br>
Risk: Cron or background-agent setup can run recurring memory updates without an active manual prompt. <br>
Mitigation: Prefer a manual non-cron setup first, and enable recurring jobs only after confirming how to inspect, pause, or remove them. <br>
Risk: Generated memory files may contain private user, relationship, or project context. <br>
Mitigation: Keep memory files out of version control and avoid sharing workspace artifacts that include memory/index.json, HIPPOCAMPUS_CORE.md, signals, pending memories, or dashboard output. <br>


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
**Output Type(s):** [Text, Markdown, Shell commands, Configuration, Guidance] <br>
**Output Format:** [Markdown and terminal output with JSON memory files and optional HTML dashboard files] <br>
**Output Parameters:** [1D] <br>
**Other Properties Related to Output:** [Creates and updates local memory artifacts under the configured OpenClaw workspace.] <br>

## Skill Version(s): <br>
3.8.6 (source: frontmatter, changelog, server release metadata) <br>

## Ethical Considerations: <br>
Users should evaluate whether this skill is appropriate for their environment, review any generated or modified files before relying on them, and apply their organization's safety, security, and compliance requirements before deployment. <br>
