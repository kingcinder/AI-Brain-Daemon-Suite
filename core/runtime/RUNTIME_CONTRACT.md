# Runtime Contract — AI Brain Daemon Suite

Version `0.1.0`. Status: **proposal** (branch `refactor/runtime-contract`).

## Purpose

The suite's cognitive architecture (scheduled jobs, memory encode/decay/
consolidate/reflect cycles, bounded self-modification) is currently welded to
one substrate: a Linux host with systemd --user, a loopback LLM endpoint, and
a `$HOME/.hermes` workspace layout (see `REFACTOR_SURVEY.md`). This contract
extracts the *architecture* from the *substrate* so the same patterns run on
heterogeneous runtimes — the groundwork for multi-node operation (Stage 2).

The contract is a small explicit interface. A **runtime adapter** implements
it for one substrate. Job logic is written once, against the contract.

## The interface

### 1. `MemoryStore` — namespaced, traversal-safe state

Suite-relative paths only (e.g. `memory/self/growth.md`). The adapter maps
them onto the substrate's real storage.

- `read(relpath) -> str | null` — missing file is `null`, never an error.
- `write(relpath, content)` — atomic (tmp + rename where the substrate
  allows); creates parent dirs.
- `append_text(relpath, text)` / `append_jsonl(relpath, record)` — for logs
  and ledgers; append is never truncated by a concurrent writer.
- `exists(relpath) -> bool`, `list(prefix) -> [relpath]`.
- **Traversal safety (contract requirement):** `..` segments, absolute paths,
  and symlink escapes resolve to rejection (`MemoryViolation`), never to
  silent rewriting. Mirrors `core/self-mod/pathguard.py`.

### 2. `Scheduler` — cron-shaped job registration

- `schedule(spec)`, `unschedule(job_id)`, `list_jobs() -> [JobSpec]`.
- `JobSpec`: `{id, kind: "direct"|"spawn", days, hours, minutes, task,
  max_steps}`. The `days/hours/minutes` spec language is the suite's existing
  one (`deep-brain-kernel.py` `_spec_matches`; `days` uses Python
  `datetime.weekday()`: 0=Monday..6=Sunday; `"*"` = every). Times are **UTC**
  unless the adapter documents otherwise.
- The adapter decides *how* scheduling is effected (internal tick loop,
  systemd timer, cron service, …). `schedule()` must be durable across
  restarts or document that it is not.

### 3. `Mind` — invoke the substrate's mind, or `null`

- `invoke(prompt, system="", max_steps=8, timeout_s=900) -> str`.
- **Honest failure:** any failure (no endpoint, timeout, malformed reply)
  raises `MindUnavailable`. Never returns empty/silent success.
- **`mind` may be `null`.** This is the *embedded-mind pattern*: on runtimes
  where the adapter executes inside the mind's own agent context (e.g. an AI
  assistant runtime), there is no separate mind to call — the job body *is*
  the mind's work. In that pattern, job logic splits into `build_prompt()`
  (pure: gather context, render the prompt) and `complete(result_text)`
  (pure: persist results); the agent's scheduled-task dispatch performs the
  reflection between them. `ContractJob.run()` raises `ContractError` when
  `mind` is `null`, directing the caller to the split flow.

### 4. `Runtime` — the adapter

- `name`, `memory: MemoryStore`, `scheduler: Scheduler`, `mind: Mind | null`.
- `asset(relpath) -> str | null` — read-only suite-bundled assets (prompts,
  manifests), resolved against the suite root, never the workspace.
- `log(level, message, **fields)` — structured logging to the substrate's
  normal channel.
- `provenance(event, detail)` — append-only audit event
  `{ts, event, actor, detail}`. **Never raises** (best-effort); the audit
  trail must not be able to break the job it records.

### 5. `ContractJob` — portable job logic

- `spec() -> JobSpec`
- `build_prompt(runtime) -> str` — gather context from `runtime.memory` /
  `runtime.asset`, render the task text. No side effects.
- `complete(runtime, result_text, ...) -> JobResult` — persist results via
  `runtime.memory`, emit provenance, return `{ok, summary, artifacts[],
  error?}`. **Persistence is the runtime's job**, executed deterministically
  by the adapter — never left to the mind's tool-use (this closes the gap
  found in the `hippocampus_weekly_reflection` trace, where the default
  agent-loop provider had no file-write tool for `memory/self/*.md`, so the
  reflection text was produced but its persistence was unenforceable).
- `run(runtime) -> JobResult` — default implementation: provenance-audit the
  dispatch (ts, job id, provider, full task text — mirrors `_audit_spawn`),
  `mind.invoke(build_prompt(runtime))`, then `complete(...)`.

## Safety kernel — carried as contract requirements, not dropped

These are the suite's existing guarantees, restated as substrate-independent
requirements. Adapters and job logic must satisfy all of them.

- **S1 Immutable core.** `core/self-mod/*`, `core/locks/*`,
  `core/concurrency/semaphore.sh`, `core/sandbox/sandbox-run.sh`,
  `core/executive-load/calc-executive-load.sh`,
  `skills/prefrontal-cortex-memory/scripts/decide.sh`, and now
  `core/runtime/*` (this contract — the safety kernel must not be
  self-modifiable) are never self-mod targets, **at every autonomy tier**,
  enforced by path matching, not by tier config. Traversal/absolute/symlink
  escapes are rejected, never rewritten.
- **S2 Fail-safe autonomy default.** Missing, unreadable, or invalid
  autonomy state ⇒ `steward_mode`. Autonomy is never over-granted on absent
  evidence. `auto_mode` requires ALL of: graduation streak at target, zero
  unhealthy jobs, auto-rollbacks within cap — computed from persisted
  evidence, never from vibes.
- **S3 Spawn audit.** Every mind invocation is audit-logged with timestamp,
  job id, provider, and the exact task text sent.
- **S4 Verification region.** Declared tests are discovered manifest-driven
  (`capability-manifest.json` `tests: [{path, kind}]`); a missing declared
  test file counts as FAIL; any failure exits non-zero and blocks deploy.
  The verification self-test gates the gate.
- **S5 Fixture honesty.** A passing test proves the test agrees with its own
  fixture — not with production. Changing a fixture's *shape* requires
  auditing every real consumer of that structure before more test files.
- **S6 Concurrency.** At most 1 concurrent background inference; locks
  reclaim stale holders (dead PID / heartbeat-stale), never deadlock
  permanently on a crashed holder.
- **S7 Provenance.** Append-only JSONL patch DAG
  `{proposal_id, content_hash, parent_hash, timestamp, proposer, reviewer,
  sandbox_score, utility_score, rollback_status}` plus a generic
  append-only autonomy event trail. Logging never fails the caller.
- **S8 Rollback thresholds.** Reject/auto-rollback on: task-success decrease
  > 3%, latency increase > 20% (only against a measured baseline — never a
  unitless default), memory/KV increase > 15%, or any regression failure.
- **S9 Deploy discipline.** Re-run target checks at deploy; snapshot first;
  back up targets; hold the write lock from check through apply;
  divergence-check and retest on drift; write a deploy record for the
  monitor. Restore order: file backups → VCS (best-effort) → snapshot.
- **S10 Proposal gating.** Targets require a valid manifest
  (`schema == 1`, `immutable == false`); new modules must ship a manifest
  with ≥1 shippable declared test. Graduation streak (20 clean) gates review
  relaxation; any sandbox/checklist/test failure resets it.

## Adapters in this tree

| Adapter | Substrate | `mind` | Notes |
|---|---|---|---|
| `adapters/codypc.py` | codypc Linux host | subprocess → `core/spawn/spawn-provider.sh` | Preserves the existing path exactly; kernel untouched |
| `adapters/juno.py` | AI-assistant agent runtime | `null` (embedded-mind) | File-backed memory w/ Juno markdown conventions; scheduler emits schedule-request docs installed agent-side via the cron tool |

### Juno adapter — honest capability mapping

The agent runtime exposes: file read/write, shell exec, cron-job
management (via the agent's cron tool — **not** callable from adapter code),
and markdown memory files (`~/memory/YYYY-MM-DD.md` daily logs). The adapter
therefore:

- `JunoMemoryStore`: file-backed, rooted at a configurable dir, 1:1
  suite-relative mapping with atomic writes and traversal rejection. Content
  stays markdown with dated `##` sections (the job logic formats entries that
  way), consumable by the runtime's memory indexer. Production wiring (real
  `~/memory` daily log) is performed by the agent's scheduled-task body,
  documented here, not hidden in the adapter.
- `JunoScheduler.schedule(spec)`: writes a **schedule-request document**
  (`{action, id, schedule{kind,dow,time,timezone}, title, body}`) under
  `{root}/schedule-requests/`. Installing it is agent-mediated (the cron
  tool), because adapter code cannot call agent tools. `unschedule()` writes
  a removal request. Nothing is pretended into existence.
- `mind` is `None`: the weekly-reflection flow on this runtime is
  cron-fire → agent runs `build_prompt()` → agent reflects → agent calls
  `complete(reflection_text)`. The vertical-slice demo below executes exactly
  this flow with the agent in the loop.

### codypc adapter — preservation, not replacement

- `CodypcMemoryStore`: `$WORKSPACE`-rooted, atomic tmp+rename writes,
  traversal rejection mirroring `pathguard`.
- `CodypcScheduler`: persists `JobSpec`s to
  `$WORKSPACE/memory/runtime-contract/jobs.json`; `to_kernel_job()`
  converts a spec to the `deep-brain-kernel.py` `Job(...)` entry shape for
  future wiring. The kernel itself is **not modified** by this branch.
- `CodypcMind.invoke()`: `exec`s
  `bash core/spawn/spawn-provider.sh --task <prompt>` with `WORKSPACE`,
  `SPAWN_PROVIDER` (default `agentloop`), `AGENT_SESSION_ID=<job-id>`,
  bounded by `timeout_s`. Non-zero exit / timeout / missing shim →
  `MindUnavailable` with a stderr tail. The existing spawn path is preserved
  bit-for-bit; the contract just gives it a typed boundary.

## Vertical slice — weekly self-reflection

`jobs/weekly_reflection.py` implements `hippocampus_weekly_reflection`
(Sundays 02:44 UTC, `days="6"`) against the contract:

1. `build_prompt()`: loads `prompts/self-reflect.md` +
   `prompts/weekly-reflection-event.md` via `runtime.asset()`, reads prior
   `memory/self/{growth,opinions,identity}.md` via `runtime.memory` for
   continuity, renders the six weekly questions ("How have I changed this
   week? … Be honest, not performative.").
2. Mind (codypc) or agent (juno) produces the reflection text.
3. `complete()`: appends the dated reflection to the growth record,
   applies `opinions_update` / `identity_update` when the mind supplies them,
   emits the `job.completed` provenance event, returns artifacts.

Demo (no live mind required):
`python3 -m core.runtime.demo --adapter {codypc|juno} --workspace /tmp/x`
runs `build_prompt` → feeds a sample reflection (or `--reflection-file`) →
`complete` → prints the `JobResult` and the artifacts written. The codypc
mind path is exercised separately by `--exercise-mind` (expects failure
without a local endpoint — asserts the failure is `MindUnavailable`, not
silence).

## What this branch does NOT do

- No changes to `deep-brain-kernel.py`, the scheduler, any skill, or the
  live deployment. The codypc path is preserved, not replaced.
- No new network surface, no credentials, no remote inference.
- `core/runtime/*` is added to `core/self-mod/immutable-paths.list`: the
  contract is safety infrastructure and must not be self-modifiable. (Decision
  for Dyther to ratify or revert.)
- Open item (from the safety survey): the memory/KV-increase rollback
  threshold is currently unmeasured in sandbox evaluation; the contract keeps
  it deploy-monitor-only until a KV metric exists.
