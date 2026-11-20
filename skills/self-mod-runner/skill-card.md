## Description: <br>
Daemon-facing entrypoints for the Phase 3 self-modification monitor loop. The pipeline lives under core/self-mod/ (Immutable Core for proposal targets); this skill invokes the monitor and the scheduled proposal cycle. <br>

Ported into the bash AI Brain Suite on 2026-11-08 from the kernel lineage (GitHub kingcinder/AI-Brain-Daemon-Suite @ 11b3db1), per Dyther's decision #7. <br>

## Skill Version(s): <br>
0.1.0 (source: capability-manifest.json) <br>

## Skill Output: <br>
**Output Type(s):** [Text, Markdown, Shell commands, Configuration] <br>
**Other Properties Related to Output:** [Creates and updates local state artifacts under the configured workspace (default ~/.openclaw/workspace).] <br>
