# AI Brain Suite

## Overview

The AI Brain Suite is a unified scheduling and pressure-management engine
(`deep-brain-kernel.py`) for 11 neurologically-mapped memory skills
(hippocampus, amygdala, VTA, basal ganglia, insula, anterior cingulate/ACC,
PFC, social, cerebellum, heartbeat). It replaces the per-skill cron entries
each skill originally shipped with — consolidating every job into one table
surfaced 11 real, pre-existing schedule collisions that were invisible while
scattered across 11 separate `install.sh` files. See
`BRAIN_DAEMON_SCHEDULE.md` for the full old-cron → new-daemon mapping.

This package reconciles two previously-separate lines of work into one
product: the skills bundle (all 11 skills, with a fixed ACC encoding script —
see below) and the daemon engine itself, which has moved from a bash
implementation to a more capable Python one (`deep-brain-kernel.py` +
`aibrain.service`). The bash version is retained, working and unmodified,
under `legacy-IGNORE/` for rollback only — see `legacy-IGNORE/README.md`.

## Contents

| Path | Purpose |
|---|---|
| `deep-brain-kernel.py` | **The engine.** Async scheduler + pressure supervisor: epoll-driven PSI monitoring, GPU VRAM checking, cgroups v2 throttling, pidfd-based process tracking, single-instance locking. `--check` validates the job table without starting anything. |
| `aibrain.service` | Systemd (user) unit supervising `deep-brain-kernel.py`, using systemd's own delegated cgroup controls rather than hand-rolled cgroup paths. |
| `skills/` | All 11 skill packages. `anterior-cingulate-memory` includes a fix (see below) so every skill's LLM-backed encoding runs against your local model, none against a paid cloud API. |
| `SETUP_COMMANDS.md` | Host-level verification steps (PSI, cgroup v2 delegation, GPU tooling) to run once before or after enabling the service. |
| `docs/V4_STATUS.md` | V4.0 phase ledger (plumbing vs live-exercised; full-cycle close-out pointer). |
| `docs/verification/` | Verification evidence; canonical GREEN pack: `full_cycle_20260720T234945Z/`. |
| `BRAIN_DAEMON_SCHEDULE.md` | Migration reference: exact old-cron schedules and the collisions consolidation found. |
| `install.sh` | Automates workspace setup, deployment, host prerequisite checks, pre-flight validation, and service activation. |
| `legacy-IGNORE/` | Prior bash daemon (`brain-daemon.sh`) — **not live**; live engine is `deep-brain-kernel.py`, fully working, kept for rollback only. Not used by `install.sh`. |
| `tests/pfc_decide_harness.sh` | Closed-loop verification that `prefrontal-cortex-memory/scripts/decide.sh` actually changes its output based on sibling state (not just documented to) — synthetic sibling state files, 7 pass/fail assertions, no LLM or real siblings required. Run: `bash tests/pfc_decide_harness.sh`. |

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
which is part of why both are kept separate rather than merged.


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
  `openclaw sessions:spawn` call is killed via its pidfd rather than left to
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

   1. **Initializes the workspace** — `~/.openclaw/workspace/skills/` and
      `~/.config/systemd/user/`.
   2. **Deploys artifacts** — `deep-brain-kernel.py` to the workspace root,
      `aibrain.service` to the systemd user directory, all 11 skills into
      `~/.openclaw/workspace/skills/`.
   3. **Sets permissions** on the engine and every skill script.
   4. **Checks host prerequisites** — PSI availability, cgroup v2, GPU
      tooling — printing a warning (not a hard failure) for anything
      missing, since the engine degrades gracefully either way.
   5. **Runs `--check`** — validates all 20 jobs' script paths, minute uniqueness, and day-of-week
      uniqueness. Stops here if anything's actually broken.
   6. **Pauses** so you can review/edit `aibrain.service` for the gotchas
      below.
   7. **Integrates with systemd** (`daemon-reload`) and **activates** the
      service.
   8. **Verifies** the service is active and prints status.

## Configuration / Gotchas

* **WORKSPACE / PATH** — `systemctl --user` services don't inherit your
  shell's environment. `aibrain.service` sets `WORKSPACE=%h/.openclaw/workspace`
  and a minimal `PATH`; if logs show `openclaw`/`jq`/`curl`/`python3`/
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
python3 ~/.openclaw/workspace/deep-brain-kernel.py --check
```

## Checking Job Health

`--check` only validates the job table (script paths, minute collisions) —
it says nothing about whether jobs are actually succeeding once the daemon
is live. For that:

```bash
python3 ~/.openclaw/workspace/deep-brain-kernel.py --status
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

## Decommissioning the Old Cron Jobs

Once the daemon's been running cleanly for a full day (so every once-daily
job gets a chance to fire and succeed), remove the old per-skill cron
entries it replaces — see `BRAIN_DAEMON_SCHEDULE.md` for the full mapping.

## Maintenance

```bash
systemctl --user stop aibrain.service
systemctl --user disable aibrain.service
rm ~/.config/systemd/user/aibrain.service
rm ~/.openclaw/workspace/deep-brain-kernel.py
```
