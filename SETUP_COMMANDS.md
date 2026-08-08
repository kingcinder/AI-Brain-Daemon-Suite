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
`heapUsage`) and adjust the parsing there if your version's output shape
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
# expect: all 18 jobs listed, zero minute collisions, hermes found

journalctl --user -u aibrain.service -f
# watch for clean "completed" lines as scheduled jobs fire; let it run at
# least one full day before removing any old cron entries, so every
# once-daily job gets a chance to fire and be observed succeeding
```
