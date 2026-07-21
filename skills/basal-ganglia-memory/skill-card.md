## Description: <br>
Habit formation and procedural learning for AI agents. Develops preferences and shortcuts through repetition. Tracks cue-routine-reward loops, chunked procedures, and active suppressions. Part of the AI Brain series. <br>

This skill is ready for commercial/non-commercial use. <br>

## Publisher: <br>
[ImpKind](https://clawhub.ai/user/ImpKind) <br>

### License/Terms of Use: <br>
Open use — commercial and non-commercial. <br>

## Use Case: <br>
Gives AI agents a basal-ganglia analog: repeated behavioral patterns crystallize into habits, multi-step workflows compact into procedures, and corrections that stick become suppressions. Active habits are injected into session context so the agent behaves consistently without re-deriving preferences from scratch each turn. <br>

### Deployment Geography for Use: <br>
Global <br>

## Known Risks and Mitigations: <br>
Risk: Habits may encode incorrect behaviors if early interactions contain errors. <br>
Mitigation: Use `reinforce-habit.sh --id <id> --weaken` to reduce misfire strength, or `--suppress` to add an explicit suppression. <br>
Risk: `habit-state.json` contains behavioral patterns that may be sensitive. <br>
Mitigation: Add `habit-state.json` to `.gitignore`. All data remains local. <br>
Risk: Suppression decay may allow previously-corrected behavior to resurface. <br>
Mitigation: Suppressions decay at 0.5%/day (much slower than habits). Reinforce critical suppressions manually. <br>

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
**Output Type(s):** [Shell scripts, JSON data, Markdown] <br>
**Output Format:** [habit-state.json, BASAL_GANGLIA_STATE.md, brain-dashboard.html, brain-events.jsonl] <br>
**Output Parameters:** [Persistent; updated by encoding cron and manual CLI calls] <br>

## Skill Version(s): <br>
0.2.2 (source: _meta.json, SKILL.md, CHANGELOG.md) <br>

## Ethical Considerations: <br>
Habit data reflects the agent's behavioral patterns and interaction history. Users should treat `habit-state.json` as private, review encoded habits periodically, and apply their organization's data-handling requirements before deployment. The suppression system is a corrective tool, not a safety guarantee — it should not be relied upon as the sole mechanism for preventing undesired behavior. <br>
