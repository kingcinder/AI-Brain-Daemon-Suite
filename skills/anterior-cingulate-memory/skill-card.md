---
id: anterior-cingulate-memory
name: Anterior Cingulate Memory
emoji: "⚡"
tagline: "Conflict detection and uncertainty monitoring for AI agents"
version: "1.0.0"
author: ImpKind
license: MIT
repo: https://github.com/ImpKind/anterior-cingulate-memory
hub: https://www.clawhub.ai/skills/anterior-cingulate-memory
tags: [memory, monitoring, conflict, uncertainty, ai-brain]
series: AI Brain
requires: [jq, bc, awk, python3]
---

## What it does

Gives your AI agent a persistent sense of *something's off*.

Tracks **conflict load** — a running uncertainty metric that rises when information or instructions conflict, and decays back to baseline when things resolve. State is auto-injected into every session so the agent knows its current cognitive tension without any manual steps.

## Core signals

| Signal | Range | Meaning |
|--------|-------|---------|
| Conflict Load | 0.0–1.0 | Overall uncertainty pressure |
| Active Conflicts | count | Unresolved contradictions |
| Attention Flags | list | Topics needing extra care |
| Uncertainty Zones | map | High-uncertainty subject areas |

## Load levels

| Load | Status | Agent behavior |
|------|--------|----------------|
| < 0.2 | 🟢 Clear | Proceed confidently |
| 0.2–0.4 | 🟡 Low | Note ambiguities |
| 0.4–0.6 | 🟠 Moderate | Verify key claims |
| 0.6–0.8 | 🔴 Elevated | Ask before proceeding |
| > 0.8 | 🚨 Critical | Explicit caution required |

## Complement to acc-error-memory

| Skill | Timing | Focus |
|-------|--------|-------|
| **anterior-cingulate-memory** | Real-time | Proactive conflict detection |
| acc-error-memory | Post-correction | Reactive error pattern tracking |

Install both for complete ACC coverage.

## Part of the AI Brain series

hippocampus · amygdala-memory · vta-memory · acc-error-memory · **anterior-cingulate-memory** · basal-ganglia-memory · insula-memory
