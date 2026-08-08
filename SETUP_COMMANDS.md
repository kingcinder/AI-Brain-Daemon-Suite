# System Setup — deep-brain-kernel.py (Ubuntu 24.04 / kernel 6.8+)

## What's NOT here, and why

The original ask included granting `CAP_BPF`/`CAP_PERFMON` file capabilities
and installing `python3-bpfcc` for an eBPF kprobe on `oom_kill_process`. That
pillar isn't built — see the top of `deep-brain-kernel.py` for the full
reasoning, in short: the Linux OOM killer operates on system RAM, and has no
visibility into GPU VRAM at all, so it wouldn't observe the actual failure
mode ("crashed local inference") this was meant to protect against. Setting
`CAP_BPF`/`CAP_PERFMON` as file capabilities on the system `python3` binary
would also grant BPF-loading privilege to every Python script any user runs
on the machine afterward — a real, systemic privilege-escalation surface,
not scoped to this daemon. Nothing below grants those capabilities or
installs bcc.

## 1. Confirm PSI is available (Pillar 1)

Ubuntu 24.04's stock kernel ships with `CONFIG_PSI=y`, so this should already
work with no action needed — confirm rather than assume:

```bash
ls /proc/pressure/
# expect: cpu  io  memory
cat /proc/pressure/memory
# expect real avg10/avg60/avg300/total values, not "No such file or directory"
```

If `/proc/pressure/` doesn't exist, PSI is disabled at the kernel level (rare
on stock Ubuntu) — `deep-brain-kernel.py` detects this at startup and runs
with pressure-based deferral disabled rather than failing; the GPU VRAM
check and circadian scheduler are unaffected either way.

## 2. Confirm rootless cgroup v2 delegation (Pillar 2)

```bash
# Confirm cgroup v2 (unified) is the active hierarchy, not the legacy v1/hybrid setup:
stat -fc %T /sys/fs/cgroup
# expect: cgroup2fs

# Confirm cpu/memory controllers are actually available to delegate:
cat /sys/fs/cgroup/cgroup.controllers
# expect to see "cpu" and "memory" in the list
```

No manual `mkdir`/`chown` under `/sys/fs/cgroup/` is needed or wanted — that
would require root and doesn't match how rootless delegation actually works.
`Delegate=yes` in `aibrain.service` is what hands this specific service its
own already-scoped cgroup subtree once it's running under
`systemctl --user`. After enabling the service, confirm delegation actually
took effect:

```bash
systemctl --user daemon-reload
systemctl --user enable --now aibrain.service
systemctl --user show -p DelegateControllers aibrain.service
# expect a non-empty list including cpu and memory
```

If that comes back empty on your system, rootless cgroup v2 delegation may
need enabling at the systemd-logind level (varies by distro/systemd
version) — `loginctl show-user $(whoami) -p Linger` and
`man systemd.resource-control` are the right next places to look; this is a
host-configuration question outside what this script can do on its own.

## 3. GPU VRAM check — Vulkan-first (this box: RX 5700 XT / RDNA1 via Mesa RADV)

`gpu_vram_percent()` checks, in order: (1) `vulkaninfo`, which queries the
Vulkan driver's own memory-budget reporting (`VK_EXT_memory_budget`) — the
same layer llama.cpp's Vulkan backend actually allocates through on this
hardware; (2) the `amdgpu` kernel driver's sysfs files
(`mem_info_vram_used`/`mem_info_vram_total`), a vendor-neutral fallback that
needs nothing installed; (3) `nvidia-smi`/`rocm-smi`, kept only for
portability on different hardware — **on this machine (RDNA1, gfx1010)
neither will ever be found, since ROCm doesn't support this GPU at all and
there's no NVIDIA hardware; that's expected, not a bug.**

Install `vulkaninfo` if it isn't already present (it likely already is, as
part of the existing llama.cpp/Vulkan inference stack):

```bash
sudo apt install vulkan-tools
which vulkaninfo
```

**Verify the parser actually matches your installed Vulkan-Tools version's
output** (stated plainly in the source too — this was not testable against
a real Vulkan/RADV install in the environment this was built in; the JSON
schema for memory-budget reporting has changed across Vulkan-Tools
releases):

```bash
vulkaninfo --json | grep -A3 heapBudget
# or, if --json isn't supported by your installed version:
vulkaninfo | grep -A3 heapBudget
```

Compare what you see against the key paths `_parse_vulkaninfo_json()` /
`_parse_vulkaninfo_text()` look for in `deep-brain-kernel.py`
(`VkPhysicalDeviceMemoryBudgetPropertiesEXT` / `heapBudget` /
`heapUsage` for stdout JSON; per-heap `size =` / `budget =` lines under
`memoryHeaps[N]:` for plain text — this host's schema, summed only over
`MEMORY_HEAP_DEVICE_LOCAL_BIT` heaps with `percent = (size − budget) /
size × 100`) and adjust the parsing there if your version's output shape
differs. If `vulkaninfo` doesn't parse cleanly for any reason, the amdgpu
sysfs fallback needs no verification at all — it reads the kernel's own
stable `mem_info_vram_used`/`mem_info_vram_total` files directly:

```bash
cat /sys/class/drm/card*/device/mem_info_vram_used
cat /sys/class/drm/card*/device/mem_info_vram_total
```

If neither Vulkan nor the amdgpu sysfs path resolves anything, the check
fails open (assumes fine, never blocks a spawn job) rather than requiring
one.

## 4. Verify everything end to end

```bash
python3 ~/.hermes/workspace/deep-brain-kernel.py --check
# expect: all 29 jobs listed, zero minute collisions, hermes found

journalctl --user -u aibrain.service -f
# watch for clean "completed" lines as scheduled jobs fire; let it run at
# least one full day before removing any old cron entries, so every
# once-daily job gets a chance to fire and be observed succeeding
```

## 5. M0 — Host-verified pillars checklist (ROADMAP M0)

M0 is the suite's "does the hardware actually do what the code claims" gate:
PSI deferral, rootless cgroup v2 delegation, and GPU VRAM parsing all built
to spec but never exercised on a real target host until now. Tick each box
with the command shown; the `▶` lines record the result on **this host**
(checked 2026-08-08). A criterion is *done* only when its box is checked.

### Criterion 1 — `--check` passes on a real machine

```bash
python3 ~/.hermes/workspace/deep-brain-kernel.py --check
# expect: exit 0, "✅ All checks passed", every job ok, zero MISSING
```

- [x] ▶ 2026-08-08: exit 0, `✅ All checks passed` — all 29 jobs (21 direct + 8 spawn) `ok`, `hermes: found`.

### Criterion 2 — deferral machinery exercised during a spawn job

**2a. PSI available (and the poll fallback, per this kernel):**

```bash
ls /proc/pressure/          # expect: cpu  io  memory
cat /proc/pressure/memory   # expect real avg10/avg60/avg300 values
journalctl --user -u aibrain.service -n 50 | grep -i "pressure"
```

- [x] ▶ 2026-08-08: `/proc/pressure/{cpu,io,memory}` present with real values. Unprivileged PSI *trigger* write returns `EINVAL` (kernel 6.8, `CONFIG_PSI=y`) — expected on this host — and the daemon logs `Falling back to avg10 poll mode`; journal shows `pressure supervisor active (memory=poll cpu=poll); threshold avg10=10.0%`. Poll-mode deferral is live.
- [ ] ▶ PSI *deferral firing during a spawn job*: not yet observed — no pressure spike has crossed the 10% threshold since the 2026-08-08 restart. Re-check under sustained load (e.g. run a local inference while a spawn job is due).

**2b. Rootless cgroup v2 delegation took effect:**

```bash
systemctl --user show -p DelegateControllers aibrain.service
# expect: non-empty list including cpu and memory
```

- [x] ▶ 2026-08-08: `DelegateControllers=cpu cpuset io memory pids` — includes `cpu` and `memory`.

**2c. GPU VRAM parsing resolves real usage:**

```bash
vulkaninfo --json 2>/dev/null | grep -c heapBudget   # this build: 0 (empty stdout; VP artifact carries no budget data)
vulkaninfo | grep -A5 memoryHeaps                     # live schema: per-heap `budget =` / `usage =` lines
cat /sys/class/drm/card*/device/mem_info_vram_total   # amdgpu sysfs fallback (no longer needed on this host)
cat /sys/class/drm/card*/device/mem_info_vram_used
```

- [x] ▶ 2026-08-08: **Vulkan memory-budget path is LIVE** (post-fix, daemon restarted onto the corrected formula 10:10:58 PDT): `_parse_vulkaninfo_text()` in `deep-brain-kernel.py` now matches this Vulkan-Tools version's per-heap schema — `memoryHeaps[N]:` blocks with `size =`/`budget =` lines, summing **only** `MEMORY_HEAP_DEVICE_LOCAL_BIT` heaps (actual VRAM; the 27 GiB host-RAM heap is excluded). Percent is `(size − budget) / size × 100` — Vulkan's `budget` is *remaining allocatable for this process* (accounts for everyone's usage), NOT total capacity, so it is used, and `usage` is deliberately ignored (it's only vulkaninfo's own trivial allocation). Live-verified against this heap while `llama-server` holds ~7.16 GiB: `size=8573157376` (7.98 GiB), `budget=881659904` (840.82 MiB free) → **~89.7%** — matching sysfs `mem_info_vram_used=7691493376` (7.16 GiB). Journal shows **no** `falling back to amdgpu sysfs` warning since the restart. The `--json` artifact (`VP_VULKANINFO_*.json`) is written to a temp cwd, so it no longer accumulates in the daemon home. Covered by `tests/test_vulkaninfo_parse.sh` (per-heap `(size−budget)/size`, host-heap exclusion, budget==size→0.0, usage-ignored, host-only→None, legacy-flat→None, VP-json→None, garbage→None).
- [ ] ▶ GPU *deferral firing*: not yet observed — VRAM is now genuinely under load (~7.16 of 8 GiB held by `llama-server`), so the gate is actually triggerable; no spawn job has yet hit the VRAM deferral threshold since the restart. Re-check while a Quality GGUF is loaded.

### Criterion 3 — `--status` clean after 24h

```bash
python3 ~/.hermes/workspace/deep-brain-kernel.py --status
# expect: real success counts, zero "⚠ UNHEALTHY" rows, exit 0
```

- [x] ▶ 2026-08-08 (pre-window): zero jobs at/above the 3-failure unhealthy threshold; exit 0. Jobs show real OK counts (e.g. `heartbeat_beat` 895 OK, `acc_conflict_encoding` 143 OK).
- [ ] ▶ **24h window**: daemon restarted 2026-08-08 08:28 PDT with the synced 29-job engine — the clean-run observation window is open; re-run this check after a full day (incl. one `verification_pass` sweep, one `brain_snapshot`, the Sunday-only weekly cycle if applicable).
