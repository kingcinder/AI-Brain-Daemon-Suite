# AI Brain Suite

[![Verification Gate](https://github.com/kingcinder/AI-Brain-Daemon-Suite/actions/workflows/verification.yml/badge.svg)](https://github.com/kingcinder/AI-Brain-Daemon-Suite/actions/workflows/verification.yml)
[![CI](https://github.com/kingcinder/AI-Brain-Daemon-Suite/actions/workflows/ci.yml/badge.svg)](https://github.com/kingcinder/AI-Brain-Daemon-Suite/actions/workflows/ci.yml)

> **Mission & scope:** see [`VISION.md`](VISION.md) — the official statement
> of what this suite is, what it is for, and where it is headed.

## Documentation Index

Six docs carry the suite's story, and they're designed to be read in this
order — each hands off to the next, so the repository reads as a single
navigable document set rather than six disconnected files:

| Doc | What it answers |
|---|---|
| [`VISION.md`](VISION.md) | What is this suite, what is it for, and where is it headed? (**read first**) |
| [`ROADMAP.md`](ROADMAP.md) | Which milestones get us to full autonomy, and which have landed (M0–M8)? |
| [`AUDIT.md`](AUDIT.md) | Which vision gaps are open or closed, and what code proves it? |
| [`HERMES_COMPATIBILITY.md`](HERMES_COMPATIBILITY.md) | How does the suite interoperate with the Hermes Agent harness? |
| [`BRAIN_DAEMON_SCHEDULE.md`](BRAIN_DAEMON_SCHEDULE.md) | What jobs does the daemon run, on what schedule, and why? |
| [`docs/V4_STATUS.md`](docs/V4_STATUS.md) | The V4.0 implementation ledger (plumbing vs live-exercised). |

## CI

Every pull request — and every night on the default branch, plus on demand
from the Actions tab — is gated by **`.github/workflows/verification.yml`**,
the manifest-driven **Verification Gate**: it validates every
`capability-manifest.json` (schema + registry rules), validates the daemon's
JOBS table with `deep-brain-kernel.py --check` (minute uniqueness, script
paths), runs the per-skill unit suite, then runs the verification region's
declared-test sweep. A PR that breaks any test a module declared — or declares
a test that doesn't exist — fails before merge. The same commands run locally
as one command — `bash scripts/ci-gate.sh` replays the gate step-for-step with
the exact CI environment (`WORKSPACE` at the checkout and
`DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1` for `--check`, isolated scratch
workspace for the sweep) — so a green local gate is a green CI run (see
`skills/verification-memory/SKILL.md` → "CI Integration").

A second schedule entry (`47 4 * * 1`, weekly Monday) runs the **deep verify**:
`bash scripts/deep-verify.sh` drives the self-mod proposal pipeline's own
sandbox gate (`core/self-mod/evaluate-proposal.sh`) with a no-op probe proposal
against HEAD, so even the proposal pipeline is drift-checked on a cadence, not
just at PR time. The probe is accepted iff every declared test passes and the
daemon job table is intact — any drift rejects it and reddens the weekly run.

## Overview

The AI Brain Suite is a unified scheduling and pressure-management engine
(`deep-brain-kernel.py`) for 11 neurologically-mapped memory skills
(hippocampus, amygdala, VTA, basal ganglia, insula, anterior cingulate/ACC,
ACC error, PFC, social, cerebellum, heartbeat). It replaces the per-skill cron entries
each skill originally shipped with — consolidating every job into one table
surfaced 11 real, pre-existing schedule collisions that were invisible while
scattered across 11 separate `install.sh` files. See
`BRAIN_DAEMON_SCHEDULE.md` for the full old-cron → new-daemon mapping.

This package reconciles two previously-separate lines of work into one
product: the skills bundle (all 15 skill packages — 11 memory skills plus
executive-function, self-mod-runner, verification-memory, and
thalamus-memory — with a fixed ACC encoding script, see below) and the
daemon engine itself, which has moved from a bash implementation to a more
capable Python one (`deep-brain-kernel.py` + `aibrain.service`). The bash
version is retained, working and unmodified, under `legacy-IGNORE/` for
rollback only — see `legacy-IGNORE/README.md`.

## Contents

| Path | Purpose |
|---|---|
| `VISION.md` | **Official vision & scope.** Persistent skills → naturalized experience synthesis → self-directed evolution → eclipsing the external harness → crystallized self-improvement. Read this first. |
| `ROADMAP.md` | **Roadmap to full autonomy.** Sequenced milestones (M0–M8) mapping the vision's three stages onto existing code — self-mod pipeline, executive cycle, daemon — each with acceptance criteria and CI-green verification. |
| `AUDIT.md` | **Living vision-gap audit.** Tracks the three vision gaps (scheduled self-mod, internalized inference, closed goal loop) — all **closed** as of 2026-08-08 — plus the agentic-loop follow-on, with per-gap status, code evidence, and closure criteria. |
| `HERMES_COMPATIBILITY.md` | **Hermes Agent compatibility audit.** File-by-file inspection of the whole suite against the installed `hermes` binary — CLI invocations, skill packaging, and nomenclature — with per-file verdicts and open items. |
| `deep-brain-kernel.py` | **The engine.** Async scheduler + pressure supervisor: epoll-driven PSI monitoring, GPU VRAM checking, cgroups v2 throttling, pidfd-based process tracking, single-instance locking. `--check` validates the job table without starting anything. |
| `aibrain.service` | Systemd (user) unit supervising `deep-brain-kernel.py`, using systemd's own delegated cgroup controls rather than hand-rolled cgroup paths. |
| `aibrain-dashboard.service` | Optional systemd (user) unit running the Brain Dashboard GUI serve mode (`scripts/serve-dashboard.sh foreground`) — boot-started, always-on, auto-restart on crash. |
| `skills/` | All 15 skill packages (11 memory skills + `executive-function`, `self-mod-runner`, `verification-memory`, `thalamus-memory`). `anterior-cingulate-memory` includes a fix (see below) so every skill's LLM-backed encoding runs against your local model, none against a paid cloud API. |
| `SETUP_COMMANDS.md` | Host-level verification steps (PSI, cgroup v2 delegation, GPU tooling) to run once before or after enabling the service. |
| `docs/V4_STATUS.md` | V4.0 phase ledger (plumbing vs live-exercised; full-cycle close-out pointer). |
| `docs/verification/` | Verification evidence; canonical GREEN pack: `full_cycle_20260720T234945Z/`. |
| `BRAIN_DAEMON_SCHEDULE.md` | Migration reference: exact old-cron schedules and the collisions consolidation found. |
| `install.sh` | Automates workspace setup, deployment, host prerequisite checks, pre-flight validation, and service activation. |
| `legacy-IGNORE/` | Prior bash daemon (`brain-daemon.sh`) — **not live**; live engine is `deep-brain-kernel.py`, fully working, kept for rollback only. Not used by `install.sh`. |
| `tests/pfc_decide_harness.sh` | Closed-loop verification that `prefrontal-cortex-memory/scripts/decide.sh` actually changes its output based on sibling state (not just documented to) — synthetic sibling state files, 7 pass/fail assertions, no LLM or real siblings required. Run: `bash tests/pfc_decide_harness.sh`. |
| `skills/verification-memory/` | **Verification region (the suite's proprioception):** runs every test each module declares in its `capability-manifest.json` `tests` array (manifest-driven, zero per-region wiring), publishes `tests_passed`/`test_failure` signals into the brain's routing table, is scheduled daily as `verification_pass` in `deep-brain-kernel.py`, and is the self-mod pre-deploy regression gate (`core/self-mod/evaluate-proposal.sh` runs the sweep + `deep-brain-kernel.py --check` in its sandbox; phase1 fallback). Long-term health: `query-history.sh` computes per-module pass-rate history over the report ledger, with a sparkline + healthiest/unhealthiest region in the dashboard tab. It also gates CI: `.github/workflows/verification.yml` runs manifest validation + the daemon job-table check (`deep-brain-kernel.py --check`) + the unit suite + this sweep on every pull request, nightly on the default branch, and on demand from the Actions tab. Run: `bash skills/verification-memory/scripts/run-declared-tests.sh`. On a fresh workspace, `backfill-history.sh` seeds the report ledger with historical runs (derived from the real sweep result, `source=backfill`) so the 🩺 sparkline shows a trend immediately instead of a single bar. |
| `tests/test_verification_region.sh` | verification-memory self-test — the gate that gates the gate (auto-included in the unit suite). Run: `bash tests/test_verification_region.sh`. |
| `scripts/ci-gate.sh` | One-command local replay of the CI Verification Gate — runs the same four commands with the exact CI env (`WORKSPACE` at the checkout + `DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1` for `--check`, isolated scratch workspace for the sweep). Run: `bash scripts/ci-gate.sh`. |
| `scripts/deep-verify.sh` | One-command local replay of the weekly deep verify — runs the self-mod proposal pipeline's sandbox gate (`core/self-mod/evaluate-proposal.sh`) against HEAD with a no-op probe proposal, accepted iff every declared test passes and the daemon job table is intact (the workflow's weekly `47 4 * * 1` schedule entry). Run: `bash scripts/deep-verify.sh`. |
| `scripts/serve-dashboard.sh` | **Always-on GUI serve mode for the Brain Dashboard.** Serves `$WORKSPACE/brain-dashboard.html` on a fixed port (default `8123`) with auto-refresh — the page polls the server and reloads itself the instant a job regenerates the file, instead of a one-off `python3 -m http.server` showing stale data. `start`/`stop`/`status`/`restart`/`foreground`; self-heals a missing dashboard on start. Run: `bash scripts/serve-dashboard.sh start`. |
| `core/agent-loop/` | **Internal agentic loop** (AUDIT Gap 2 follow-on): a multi-turn tool-use loop (`agent-loop.sh`) with an allowlisted tool registry (`tools.sh`) and session memory, running against the suite's local LLM — `SPAWN_PROVIDER=agentloop` routes daemon spawn jobs through it with no hermes needed. |
| `core/self-mod/acc-calibration.sh` | **ACC flag→error calibration** (Stage-1 proprioception): joins anterior-cingulate conflict flags to acc-error corrections over a rolling window and reports how often flagged uncertainty actually predicted a later error (hit rate, false-positive rate, per-type breakdown). Read-only; feeds `health-context.sh` and the proposal prompts. |

### Why are there two ACC skills?

`anterior-cingulate-memory` and `acc-error-memory` both map to the anterior
cingulate cortex and can look redundant at a glance — they're not the same
skill split in two, they cover two different timings of the same brain
region's job:

| | `anterior-cingulate-memory` ⚡ | `acc-error-memory` 🔴 |
|---|---|---|
| **Fires on** | The agent noticing conflicting information, ambiguous intent, or rising uncertainty *while reasoning, before acting* | A correction the user actually made, *after* the agent said or did something wrong |
| **Nature of signal** | Predictive / a "something feels off" flag | Confirmed / a recorded mistake |
| **Job in `deep-brain-kernel.py`** | `acc_conflict_encoding`, `acc_conflict_decay` (`direct`) | `acc_error_analysis` (`spawn`) |

**Routing rule when it's not obvious which one applies:** if the signal
exists before the agent commits to an action or answer, it's
`anterior-cingulate-memory`'s. If it exists only because the user pointed
out something was already wrong, it's `acc-error-memory`'s. It's normal —
not duplicate logging — for the same underlying issue to show up in both:
`anterior-cingulate-memory` recording "flagged uncertainty about X" during
the session, and `acc-error-memory` later recording "corrected on X" if the
uncertain guess turned out wrong. That pairing is itself useful signal
(calibration: how often does flagged uncertainty predict an actual error?),
which is part of why both are kept separate rather than merged. That
question — "how often does flagged uncertainty predict an actual error?" —
is now answered quantitatively by `core/self-mod/acc-calibration.sh`
(Stage-1 proprioception), which joins the conflict flags to the error
corrections over a rolling window and reports the hit rate per conflict
type.


## Why the engine moved from bash to Python

The legacy `brain-daemon.sh` (not live) read `/proc/pressure/{memory,cpu}` on a
30-second timer and had no idea whether your GPU was actually busy — it
could fire a job into the middle of active local inference. It also had no
race-free way to track or terminate child processes. `deep-brain-kernel.py`
was built to address exactly that, and to genuinely test what it claims:

- **Pillar 1 — PSI, trigger-first with poll fallback.** Prefers a real
  kernel PSI trigger via `epoll` (Linux 4.20+). On this host, unprivileged
  trigger *writes* return **EINVAL** (`CONFIG_PSI=y`; reads still work); the
  daemon then arms **avg10 poll mode** so pressure deferral still works
  without root. See `docs/verification/full_cycle_20260720T234945Z/psi_fresh_diagnosis.txt`.
- **Pillar 2 — cgroups v2 CPU throttling**, written into the subtree systemd
  has *already delegated* to this service (`Delegate=yes` in the unit file),
  not an invented top-level path an unprivileged user couldn't create anyway.
- **Pillar 3 — race-free process tracking**, via `pidfd_open` +
  `pidfd_send_signal` (a raw syscall bridged through `ctypes`, since CPython
  doesn't expose it directly) — a stale pidfd correctly fails against a
  since-exited, possibly PID-reused process instead of risking signaling the
  wrong one.
- **Per-job execution timeouts** (`--direct-timeout`, default 300s;
  `--spawn-timeout`, default 900s) — a hung script or a stuck
  `hermes chat` call is killed via its pidfd rather than left to
  run forever. This matters most for spawn jobs specifically: they share one
  lock (only one real agent turn runs at a time), so without a timeout a
  single hung call would silently starve every other spawn-type job
  indefinitely — confirmed with a real hung-subprocess test before this fix.
- **GPU VRAM awareness (new, bash had none of this)** — checks
  `nvidia-smi`/`rocm-smi` before firing a `spawn`-type job, deferring if VRAM
  usage is at or above a configurable limit (default 80%). Fails open if
  neither tool is present.
- **What was explicitly NOT built, and why** — an eBPF kprobe on
  `oom_kill_process` was in the original ask but is not implemented: the
  Linux OOM killer only sees system RAM, never GPU VRAM, so it wouldn't
  observe the failure mode ("crashed local inference") this was meant to
  protect against, and wiring up BCC would require granting `CAP_BPF`/
  `CAP_PERFMON` file capabilities on the system `python3` binary — a
  privilege-escalation surface for *every* Python script on the machine, not
  scoped to this daemon. PSI + GPU VRAM checking covers the actual goal
  without that cost. Full reasoning is in the script's own header comment.

**Honestly flagged, not glossed over:** `pidfd_send_signal` and PSI parsing
were tested directly against real processes/sample data during development.
PSI's `epoll` trigger registration, cgroup delegated-path resolution, and
`rocm-smi`/`nvidia-smi` parsing were built to the documented interfaces but
**not** exercised against a real kernel PSI trigger, a real delegated
cgroup, or real GPU tooling in the environment this was built in (no
`/proc/pressure`, no active `systemd-logind` session, no GPU there). Confirm
these three specifically on your actual machine — `SETUP_COMMANDS.md`
walks through exactly how.

## Fixed: ACC's encoding script no longer calls a paid cloud API

`anterior-cingulate-memory/scripts/encode-pipeline.sh` previously called the
Anthropic API directly (requiring `ANTHROPIC_API_KEY`), which was
inconsistent with every other skill's local-only, zero-cost design — e.g.
PFC's `semantic-match.sh`. It's been rewritten to call your local LLM server
through the same shared `llm-call.sh` utility PFC uses (`llm-call.sh` and
`safe-write.sh` are now bundled into ACC's own `scripts/` folder, the way PFC
already carries its own copies). No API key, no per-call cost, no cloud
dependency — consistent with the rest of the suite. State writes go through
`safe-write.sh`'s lock-guarded pattern rather than an unguarded read/write.

## Installation

1. Extract this package.
2. From inside the extracted directory, run:

   ```bash
   chmod +x install.sh
   ./install.sh
   ```

   `install.sh`:

   1. **Initializes the workspace** — `~/.hermes/workspace/skills/` and
      `~/.config/systemd/user/`.
   2. **Deploys artifacts** — `deep-brain-kernel.py` to the workspace root,
      `aibrain.service` to the systemd user directory, all 15 skill packages
      into `~/.hermes/workspace/skills/`.
   3. **Sets permissions** on the engine and every skill script.
   4. **Checks host prerequisites** — PSI availability, cgroup v2, GPU
      tooling — printing a warning (not a hard failure) for anything
      missing, since the engine degrades gracefully either way.
   5. **Runs `--check`** — validates all 29 jobs (21 direct + 8 spawn): the 21 direct jobs' script paths, and minute + day-of-week
      uniqueness across all. Stops here if anything's actually broken.
   6. **Pauses** so you can review/edit `aibrain.service` for the gotchas
      below.
   7. **Integrates with systemd** (`daemon-reload`) and **activates** the
      service.
   8. **Verifies** the service is active and prints status.

## Configuration / Gotchas

* **WORKSPACE / PATH** — `systemctl --user` services don't inherit your
  shell's environment. `aibrain.service` sets `WORKSPACE=%h/.hermes/workspace`
  and a minimal `PATH`; if logs show `hermes`/`jq`/`curl`/`python3`/
  `nvidia-smi`/`rocm-smi` "not found" despite working in your terminal, run
  `which <tool>` and add the real paths to the unit's `PATH=` line.
* **cgroup delegation** — confirm it actually took effect after enabling:
  `systemctl --user show -p DelegateControllers aibrain.service` should list
  `cpu` and `memory`. If empty, see `SETUP_COMMANDS.md` §2 — this is a
  host/systemd-version question, not something the script can force.
* **`Nice=-5`** — gives this daemon's jobs higher CPU scheduling priority
  than your normal interactive processes. Real trade-off, not a free win;
  reconsider it if the machine feels laggy while a `spawn` job runs.
* **GPU VRAM parsing** — the `rocm-smi --showmeminfo vram --json` key names
  the script looks for were not verified against a real ROCm install. Run
  that command yourself and compare against what `gpu_vram_percent()` in
  `deep-brain-kernel.py` expects before trusting it unattended.

## Verifying the Install

```bash
systemctl --user status aibrain.service
journalctl --user -u aibrain.service -f
python3 ~/.hermes/workspace/deep-brain-kernel.py --check
```

## Checking Job Health

`--check` only validates the job table (script paths, minute collisions) —
it says nothing about whether jobs are actually succeeding once the daemon
is live. For that:

```bash
python3 ~/.hermes/workspace/deep-brain-kernel.py --status
```

Read-only, safe to run anytime, doesn't need the daemon stopped or the
lock. Prints each job's success/failure counts and current
consecutive-failure streak (jobs at 3+ in a row are flagged
`⚠ UNHEALTHY`, along with the last error seen). Exit code is the number of
unhealthy jobs, so it doubles as a monitoring check, e.g. in a cron line:
`--status || mail -s "aibrain job failing" you@example.com`.
Deferrals (VRAM limit, PSI pressure, missing `hermes`, missing script) are
deliberately not counted as failures — only jobs that actually ran and then
errored or timed out.

## Dashboard GUI (serve mode)

The suite's visual dashboard (`$WORKSPACE/brain-dashboard.html`, assembled
from every skill's fragment by the shared `dashboard-builder.sh`) can be
served as an always-on GUI instead of a one-off static-file open:

```bash
bash scripts/serve-dashboard.sh start    # → http://127.0.0.1:8123/brain-dashboard.html
bash scripts/serve-dashboard.sh status
bash scripts/serve-dashboard.sh restart
bash scripts/serve-dashboard.sh stop
```

`start` launches the stdlib-only Python server (`scripts/dashboard-server.py`)
on a **fixed port** (default `8123`, override with `DASHBOARD_PORT`;
`DASHBOARD_HOST` defaults to loopback-only `127.0.0.1`) and **auto-refreshes**:
the served page injects a tiny poller that watches the dashboard file's mtime
via `GET /__dashboard_mtime` and calls `location.reload()` the instant a job
regenerates it — no manual refresh, and your selected tab survives reloads
(the builder persists it in `localStorage`). If `brain-dashboard.html` is
missing, `start` builds it first via the shared builder, so it self-heals on a
fresh workspace.

The dashboard shell is **live**: a status bar under the header re-fetches
`GET /__fragments` and `GET /__daemon` every 10s, showing the daemon
heartbeat (last beat + age), the most recent successful job run, the live
fragment count, a per-job success-rate **sparkline**, the autonomy-contract
pill (`🛡 steward` / auto) from `deep-brain-kernel.py --autonomy`, a health
flag for jobs at 3+ consecutive failures, and a `⏸ cycle` pill that lights up
when the weekly self-mod cycle deferred for a human (steward_mode +
full_review). The 🩺 verification tab renders the **autonomy contract
history** (when and why auto_mode was granted or revoked, from the
provenance ledger), and the 🛠 Self-Mod tab shows the last 12 `autonomy.*`
audit events as an **Autonomy Gate · Provenance** timeline. A
**🔄 Regenerate** button POSTs to `POST /__regenerate`, which runs every
skill's `sync-state.sh` (falling back to `generate-dashboard.sh`) across
`skills/*` and rebuilds the dashboard in place — a live, token-gated
mutation (the server injects a per-session token into the page; cross-origin
POSTs can't supply it, so only the dashboard itself can trigger a rebuild).

For a **boot-started, always-on** GUI, install the optional systemd user unit
(`aibrain-dashboard.service`) — same install pattern as `aibrain.service`
(copy `scripts/serve-dashboard.sh` + `scripts/dashboard-server.py` into your
workspace's `scripts/`, copy the unit to `~/.config/systemd/user/`, edit the
`Environment=` lines for your workspace, then
`systemctl --user enable --now aibrain-dashboard.service`). Auto-restarts on
crash, logs to journald. Only expose `DASHBOARD_HOST=0.0.0.0` on a trusted
network.

## Decommissioning the Old Cron Jobs

Once the daemon's been running cleanly for a full day (so every once-daily
job gets a chance to fire and succeed), remove the old per-skill cron
entries it replaces — see `BRAIN_DAEMON_SCHEDULE.md` for the full mapping.

## Maintenance

```bash
systemctl --user stop aibrain.service
systemctl --user disable aibrain.service
rm ~/.config/systemd/user/aibrain.service
rm ~/.hermes/workspace/deep-brain-kernel.py
```
