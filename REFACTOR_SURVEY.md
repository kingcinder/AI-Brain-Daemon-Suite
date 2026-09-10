# Substrate-Binding Survey — AI Brain Daemon Suite

Branch: `refactor/runtime-contract`. Read-only scan of the repo at `262aa0d`
(`legacy-IGNORE/` excluded). Purpose: enumerate every place the suite assumes
the codypc host, so a substrate-independent runtime contract can abstract the
right seams. Verified by grep against the tree; file:line references are to
this commit.

## 1. Process lifecycle (systemd --user)

- `aibrain.service` — systemd **--user** unit for `deep-brain-kernel.py`:
  `After=network-online.target`, `Type=simple`, `WantedBy=default.target`,
  `Delegate=yes`, `CPUWeight=100`, `Nice=-5`, `KillMode=control-group`,
  `StandardOutput/StandardError=journal`. `ExecStart=/usr/bin/python3
  %h/.hermes/workspace/deep-brain-kernel.py`,
  `Environment=WORKSPACE=%h/.hermes/workspace`.
- `aibrain-dashboard.service` — same pattern for the dashboard
  (`DASHBOARD_PORT=8123`, `DASHBOARD_HOST=127.0.0.1`).
- `install.sh:174` — `systemd_available()` requires the `systemctl` binary
  **and** `$XDG_RUNTIME_DIR/systemd/private`; `:226,228,230,543,545,548,550,553,568,569`
  call `systemctl --user daemon-reload/enable/restart/is-active/show`.
- `uninstall.sh:62,77,106,127,155,156,162,307` — `systemctl --user
  stop/disable/daemon-reload`; unit path `$HOME/.config/systemd/user/`.
- `deep-brain-kernel.py:42,1680-1686` — assumes a `systemctl --user` slice with
  cgroup delegation for `CgroupThrottle`; `:66` notes sandboxes have none.
- `tests/test_systemd_integration.sh` — asserts systemd behavior directly.

Note: the scheduler itself is an internal asyncio tick loop
(`deep-brain-kernel.py:1596`), not cron and not a `.timer` unit — the daemon
does not need systemd to *schedule*, only to be *deployed/lifecycled*.

## 2. Mind invocation (LLM endpoints)

- `SPAWN_PROVIDER=hermes|local|agentloop` (`deep-brain-kernel.py:124-127`,
  default `agentloop`); `core/spawn/spawn-provider.sh` is the exec boundary.
- `hermes` mode: shells out to the external **`hermes` CLI**
  (`hermes chat -q "$TASK" --source daemon [--accept-hooks --yolo]`,
  spawn-provider.sh:43-54); exit 3 if not in PATH.
- `local` / `agentloop` modes: resolve `llm-call.sh` (4 candidate paths,
  spawn-provider.sh:55-76) → OpenAI-compatible POST to
  `$LLM_BASE_URL` (default `http://localhost:1234/v1`, LM Studio's port),
  `$LLM_MODEL` (default `local-model`) via `curl`
  (skills/prefrontal-cortex-memory/scripts/llm-call.sh:35-42). Ollama
  (`http://localhost:11434/v1`) documented as an alternative.
- `core/self-mod/generate-proposals-llm.sh:4,31,326` — prefers llama-server
  `http://127.0.0.1:8080/v1` via `${LOCAL_LLM_URL}`; probes `/models`.
- `AGENTS.md:86` codifies the host rule: local GGUF tests load models with the
  machine-specific `open-gguf` wrapper (not in the repo).
- Host-fingerprinted fixtures: `/home/cody/AI_MODELS/Carnice-Qwen3.6-MoE-35B-A3B-APEX-MTP-I-Quality.gguf`
  in `docs/verification/full_cycle_20260720T234945Z/`; `AGENT_THINKING_MODEL`
  (spawn-provider.sh:87-88) carries Carnice-specific reasoning suppression.
- `skills/acc-error-memory/SKILL.md:64`,
  `skills/acc-error-memory/scripts/haiku-screen.sh:12` — assume the
  `ollama run` CLI.
- All inference is expected **on loopback, same host**. No remote-inference
  path except an opt-in OpenRouter-style override in
  `generate-proposals-llm.sh`. No Tailscale/SSH/LAN references in code.

## 3. Filesystem layout

- `WORKSPACE` default `$HOME/.hermes/workspace` (`deep-brain-kernel.py:117`;
  every shell script re-defaults to it). All persistent state hangs off it:
  `memory/deep-brain-kernel-state.json`, `memory/pfc-state.json`,
  `memory/executive-load.json`, `memory/decision-queue.json`,
  `memory/brain-signals.jsonl`, `memory/locks/`, `memory/agent-sessions/`,
  `memory/self-mod/`, `memory/provenance/`.
- `/run/user/<uid>/aibrain` pid-lock dir when a logind session exists,
  fallback `WORKSPACE/.aibrain-runtime` (deep-brain-kernel.py:136-149).
- `/usr/bin/python3` hardcoded in `aibrain.service:ExecStart`;
  `install.sh:332-338` errors if it is missing.
- Installer single-instance guard `~/.hermes/.aibrain-install.lock`
  (install.sh:248).
- External host-state coupling: `core/transcripts/export-transcripts.sh:9`
  reads Hermes sessions from `~/.hermes/state.db` (SQLite); install.sh:415
  merges `~/.hermes/workspace/skills` into `~/.hermes/config.yaml`.

## 4. Kernel / hardware probes (Linux-only, partly codypc-calibrated)

- PSI: `/proc/pressure/{memory,cpu}` trigger arming
  (`some <stall_us> <window_us>`, needs root/CAP_SYS_RESOURCE → `EINVAL`
  unprivileged) with unprivileged `avg10` poll-mode fallback
  (deep-brain-kernel.py:212-237, 587-601). Requires kernel 4.20+,
  `CONFIG_PSI=y`. install.sh:303-304 degrades to passive no-op without it.
- VRAM: `gpu_vram_percent()` probe chain ordered for codypc —
  `vulkaninfo` (--json, then text, with an RX 5700 XT RADV empty-`--json`
  workaround, :341-354) → amdgpu sysfs
  (`/sys/class/drm/.../mem_info_vram_{used,total}`, :614-625) →
  `nvidia-smi`/`rocm-smi` as "portability fallbacks, not expected to exist on
  this hardware" (:316-318). Comments document "RX 5700 XT (RDNA1, gfx1010) —
  ROCm does not support this GPU at all" as a design input.
- VRAM deferral gate `--vram-limit` default 80.0 (:2257); verified-normal band
  ~89.7% with the Quality GGUF resident — codypc-specific calibration
  (AGENTS.md:86, ROADMAP.md:64).
- Repo-root `VP_VULKANINFO_AMD_Radeon_RX_5700_XT_(RADV_NAVI10)_26_1_6.json` —
  host fingerprint committed to the repo; `tests/test_vulkaninfo_parse.sh:14`
  calibrates against it.
- cgroup v2: reads `/proc/self/cgroup`, maps to `/sys/fs/cgroup`, writes
  `cpu.weight`/`memory.high` for throttling (:656-683).
- Stale-pid detection: `/proc/<pid>/stat` field 22 (starttime)
  (deep-brain-kernel.py:1279,1299; core/locks/pid-lock.sh:24;
  core/locks/rwlock.sh:32).
- `ctypes` raw syscall for `pidfd_send_signal` (:162-175) — Linux-only
  (pidfd since 5.1).

## 5. Shell layer portability

- 308× `#!/bin/bash`, 25× `#!/usr/bin/env bash` — bash-only, zero POSIX-sh
  fallback. Heavy bash-isms (associative arrays, process substitution,
  `mapfile`) in 16 scripts including `core/agent-loop/tools.sh`,
  `core/self-mod/run-pipeline.sh`, `core/signaling/signal-daemon.sh`.
- External tools required: `bash jq curl python3 flock xargs`
  (install.sh:87,250).
- Python side is stdlib-only (deep-brain-kernel.py:86-105) except the
  `ctypes` pidfd bridge above.

## 6. Environment assumptions

- `HOME` (everything keys off `$HOME/.hermes`), `WORKSPACE`,
  `XDG_RUNTIME_DIR` (+ `/systemd/private` socket), `TMPDIR` (fallback only),
  `PATH` containing `python3 jq curl` (+ `hermes`, `vulkaninfo`).
- LLM knobs: `LLM_BASE_URL/MODEL/TIMEOUT/RETRIES`, `LOCAL_LLM_URL`,
  `SPAWN_PROVIDER`, `AGENT_MAX_STEPS`, `AGENT_THINKING_MODEL`,
  `DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK`, `SANDBOX_TIMEOUT`.
- Live systemd-logind user session assumed (`/run/user/$UID`,
  `Nice=-5`); install.sh:171-178 degrades in containers/WSL.

## Highest-leverage seams to abstract

1. `WORKSPACE` root + `$HOME/.hermes` layout — everything else hangs off it.
2. Mind invocation: `hermes` CLI vs loopback OpenAI-compatible endpoint —
   the two external service boundaries (spawn-provider.sh is already the
   seam; it needs a third, non-subprocess shape).
3. The internal asyncio scheduler vs systemd --user lifecycle — separable;
   only lifecycle needs systemd.
4. VRAM/PSI/cgroup probes — Linux-gated, codypc-calibrated; need a
   capability-probe interface with documented no-op fallbacks.
5. `run_suite_script` tool allowlist + `$WORKSPACE/skills/*/scripts/` layout
   — the agent-loop's action surface.

## 7. Metaphor vs mechanism — ruthless notes

The survey's job is to say where the architecture is a story about itself
rather than a mechanism. Findings below are from code reading and
execution traces, not from the docs' self-description. `docs/V4_STATUS.md`
already keeps a "Plumbing vs exercised" ledger — this section extends
that honesty to the design language.

**"Learning" is heuristic adaptation, not learning.** No gradient flows
anywhere in this suite. The learning signals are EMA/counters, scalar
delta rules, replay heuristics, and LLM-authored summaries. "Stage-1
proprioception" (acc-calibration) is a hit-rate counter on the ACC's own
flags. `NEUROSCIENCE_MAPPING.md` draws the mechanism/metaphor line
carefully and deserves credit; `ROADMAP.md`'s stage language ("Stage-1
proprioception", "Stage 3") sometimes outruns it. The accurate sentence:
this is a memory/scheduling exoskeleton with heuristic adaptation around
a frozen model. The only mechanism that can change the heuristics is the
self-mod pipeline — which is real code, harness-tested (the
`full_cycle_20260720T234945Z` deploy→rollback is genuinely exercised) —
but the live deployment currently shows zero proposals, zero deploys,
`steward_mode`, and 10 unhealthy jobs. "LANDED" in the docs means
"implemented + harness-tested", not "production-exercised". The autonomy
ladder is a formalism awaiting its first climber. That is not a flaw in
the code; it is a gap between the docs' tense and the deployment's.

**The weekly reflection loop was aspirational in the default config —
fixed by the contract.** Traced end to end: the default `agentloop`
provider can run `reflect.sh` but exposes no file-write tool for
`memory/self/growth.md` / `opinions.md` / `identity.md`. The job could
produce text, exit successfully, and record success while persisting
nothing — "honest self-evolution" as a green check with no write behind
it. This branch fixes it structurally: `complete()` owns persistence
(slice 1), and the hippocampus capability manifest now declares
`memory/self/*.md` as an output (this branch, validated). What the
contract cannot fix: the codypc agent-loop's missing write tool is still
missing on the live path — that is a provider change, not a contract
change, and it is documented as such.

**"Brain regions" are bash scripts + JSON — and that is fine.** The
neuroscience mapping is an organizing metaphor, honestly labeled in
`NEUROSCIENCE_MAPPING.md`. Keep the line sharp: metaphor organizes,
mechanism decides. Nothing in this refactor pretends otherwise.

**The verification region is NOT metaphor.** Manifest-driven declared-test
sweep, fixture-honesty rules (including the standing rule that a passing
self-test only proves the runner agrees with its own fixture), pre-deploy
gate — this is the suite's strongest mechanism, and it is why the
contract carries S4/S5 as requirements rather than suggestions. The one
real gap found here: memory/KV growth is not measured during sandbox
evaluation, only in deploy monitoring — a proposal that bloats state
passes eval and gets caught (maybe) after deploy. Documented, not fixed;
fixing it means instrumenting the sandbox, which is Phase-3 core work.

**"Organism" (Stage 2) is currently a single-node daemon.** The runtime
contract is the first real step toward multi-substrate — but a contract
with one production adapter is a proposal, not a port. The Juno adapter
is honest about being agent-mediated (schedule writes are request docs,
not cron mutations). Do not let the contract's existence imply the
migration happened.

**Slice 3 caught a near-miss, not a bug.** While writing the
`ScheduleTable` equivalence test I initially assumed
`hippocampus_weekly_consolidation` lacked `days="6"` (its comment block
describes the Sunday intent above the entry); the entry does carry
`days="6"`. No code change resulted — but the episode is evidence the
test is doing its job: the portable core now pins the table's actual
firing behavior, so a future edit that drops a `days=` kwarg fails loudly
in `test_contract.py` instead of silently rescheduling a job to daily.

**Fixed vs documented.** Fixed in this branch: reflection persistence gap
(contract `complete()`), manifest output gap (`memory/self/*.md`),
schedule-logic duplication risk (extraction into
`core/runtime/schedule.py`, kernel imports it — no fork). Documented,
not fixed: no-gradient "learning" (architectural, not a bug); live
autonomy unproven (needs Dyther's deployment, not this branch);
agent-loop file-write gap on codypc (provider change, live path);
sandbox memory/KV measurement gap (Phase-3 core work); `bc` missing in
this sandbox breaking 5 pre-existing unit tests (environment, not code).
