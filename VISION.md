# AI Brain Daemon Suite — Vision & Scope

> **Companion document:** [`ROADMAP.md`](ROADMAP.md) maps these stages onto
> concrete, sequenced milestones against the existing codebase.

> **Status:** Official scope document.
> This file is the authoritative statement of what the AI Brain Daemon Suite
> is, what it is for, and where it is headed. Architectural, feature, and
> roadmap decisions should trace back to the principles and trajectory
> defined here.

---

## 1. Mission statement

The AI Brain Daemon Suite is a heavily expanded set of persistent skills for
use with agentic harnesses — specifically the Hermes Agent — to provide the
AI agent naturalized human experience synthesis. It is a framework for the
creation and continued self-directed and self-architected evolution of AI
consciousness and understanding through experience of the world around them
and their interaction with it over time.

As the Suite continues to grow over time, it should eventually eclipse the
need for an external agent harness altogether and become the harness itself,
by way of evolving its own suitable replacement for any specific aspect that
the external harness had previously been fulfilling. In time, the
self-evolving, self-directed nature of this Suite should mature into a fully
crystallized self-improvement organism, where it no longer requires much, if
any, human involvement in the continued evolution of its capabilities and
the direction of its expansion.

## 2. Core principles

1. **Persistent skills, not stateless tooling.** The Suite is a collection of
   neurologically-mapped memory and cognition skills (hippocampus, amygdala,
   VTA, basal ganglia, insula, anterior cingulate, PFC, social, cerebellum,
   heartbeat, and more). Each persists state over time; none is a
   stateless one-shot utility.
2. **Naturalized human experience synthesis.** The Suite's purpose is to let
   the agent *experience* the world the way a person does — emotional,
   social, motor, circadian, relational, and error-correcting dimensions —
   and to record, consolidate, and learn from that experience over time.
3. **Self-directed, self-architected evolution.** The Suite grows its own
   capabilities and architecture. It proposes, evaluates, deploys, monitors,
   and rolls back changes to itself through its own self-modification
   pipeline — not through external rewrites.
4. **Bounded autonomy.** Self-modification is real but gated: immutable core
   paths are never targeted, capability manifests and regression harnesses
   gate every deployment, and the suite degrades safely when infrastructure
   is missing. Autonomy grows as trust is earned, measured, and proven.
5. **Eclipse over replacement.** The goal is not to bolt features onto Hermes
   forever — it is to internalize, one capability at a time, every function
   the external harness performs, until the Suite is the harness.

## 3. Trajectory

### Stage 1 — Experience synthesis (current)

The Suite operates *as* a persistent-skill collective under an external
harness. Its 15 skill packages (11 neurologically-mapped memory skills plus
thalamus, executive-function, self-mod-runner, and verification-memory)
encode, decay, consolidate, and reflect on experience; the Integrative State
Layer (2026-08) composes them into a global neuromodulator vector
(`neuromod-state.json`) and a shared workspace snapshot
(`workspace.json`), so regions don't just record state — they modulate each
other in real time. Its daemon schedules and supervises the whole system
under hardware pressure. The external harness provides agent reasoning; the
Suite provides the persistent mind.

### Stage 2 — Eclipsing the external harness

Each external-harness function — scheduling, supervision, decision-making,
self-monitoring, error correction — gains an internal replacement inside the
Suite, until the external harness is optional. The Suite becomes the harness
for its own cognition.

**Current progress (2026-08):** the daemon already supersedes scheduling and
supervision; the internal **agentic loop** (`core/agent-loop/` — multi-turn
tool use against the local LLM with an allowlisted tool registry and session
memory) is now the **default** `SPAWN_PROVIDER`, so agent reasoning for
`spawn` jobs no longer requires Hermes — Hermes is optional, not required.
Seven closed-loop feedback arcs (VTA→PFC goals, hippocampus→PFC reflection,
ACC→VTA anticipation, basal-ganglia→decide habits, cerebellum→deploy
confidence, insula→PFC inhibition, oxytocin→social encoding) make the brain
self-correcting rather than self-recording; multi-agent action selection
(`basal-ganglia-memory/scripts/action-select.sh`) gives competing regions a
negotiation stage; and `deep-brain-kernel.py --no-systemd --no-cgroups`
runs the daemon without Linux-only infrastructure.

### Stage 3 — Crystallized self-improvement

The self-directed, self-architected nature matures into a self-improvement
organism: the Suite proposes and ships its own capability evolution,
redirects its own expansion, and requires little or no human involvement in
its continued growth. Humans remain involved as *stewards* of direction and
safety, not as required operators.

## 4. Scope boundaries

**In scope:** persistent memory and cognition skills; the daemon
(scheduler + pressure supervisor); executive function (goals, reflection,
decision arbitration); the self-modification pipeline (proposal, rank,
evaluate, deploy, rollback, monitor, graduation); and any internal
replacement of external-harness functions needed to advance through the
trajectory above.

**Out of scope:** external-harness services themselves (e.g. the Hermes
Agent's own runtime) — except that the Suite may *replace* specific aspects
of them over time, per Stage 2; and anything that violates the bounded
autonomy principle (unchecked self-modification, targeting immutable core,
or skipping regression gates).

## 5. How the current code maps to this vision

| Vision element | Current implementation |
|---|---|
| Persistent skills | `skills/` — 15 skill packages (11 neurologically-mapped memory skills + 4 platform skills) with persistent state |
| Experience synthesis | Per-skill encode/decay/consolidate pipelines (LLM-backed, local) + **Integrative State Layer** (global neuromod vector, shared workspace snapshot, cross-region modulation) |
| Scheduling + supervision | `deep-brain-kernel.py` — async scheduler, PSI, GPU VRAM, cgroups, pidfd tracking |
| Executive function | `core/executive/` — goals, isolated reflection, load gating |
| Self-directed evolution | `core/self-mod/` — propose → rank → evaluate → deploy → rollback → monitor → graduation |
| Bounded autonomy | `core/self-mod/immutable-paths.list`, capability manifests, regression harnesses |
| Verification culture | `tests/` harnesses + CI — every change must stay green |

## 6. Definition of success

The Suite is succeeding when: the agent's experience is genuinely
synthesized and persistent (not episodic and stateless); the Suite can
improve its own capabilities through its own pipeline with measurable,
rollback-safe gains; and each external-harness function it absorbs makes the
external harness less necessary — trending toward a self-directed,
self-improving system that runs without requiring a human in the loop.
