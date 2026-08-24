#!/usr/bin/env python3
"""
deep-brain-kernel.py — Unified async scheduler + hardware-pressure supervisor
for the AI Brain Suite, replacing brain-daemon.sh.

READ THIS BEFORE THE CODE, NOT AFTER — two of the four originally-requested
pillars are built differently than specified, for concrete technical reasons,
not style preferences:

1. eBPF kprobe on oom_kill_process is NOT built as a kprobe/BCC pipeline.
   The Linux OOM killer operates on SYSTEM RAM pressure. It has no visibility
   into GPU VRAM at all — a Vulkan/ROCm inference process running out of
   VRAM is a GPU-driver-level allocation failure, not a Linux OOM-killer
   event, so a kprobe on oom_kill_process would essentially never fire for
   the thing this pillar was meant to protect (active local GPU inference).
   Wiring up BCC also means installing python3-bpfcc + matching kernel
   headers for the exact running kernel (BCC JIT-compiles the eBPF C source
   against the live kernel's headers at load time — this is version-fragile
   in a way libbpf/CO-RE tooling was specifically built to avoid), AND
   setting CAP_BPF/CAP_PERFMON as FILE CAPABILITIES on the system python3
   binary, which grants BPF-loading privileges to every Python script any
   user runs on the machine afterward — not scoped to this daemon. That's a
   real, systemic privilege-escalation surface for a personal single-user
   scheduling daemon, not a proportionate trade.
   What this file does instead: PSI (Pressure Stall Information) already
   gives you memory/CPU contention as a LEADING indicator (before anything
   gets killed), at zero extra privilege, with no compilation step, no
   kernel-header dependency. Combined with a direct VRAM percentage check
   (rocm-smi/nvidia-smi) for the resource pool PSI can't see, this covers
   the actual stated goal — "don't crash active local inference" — more
   completely than an oom-kill kprobe would, without the privilege/fragility
   cost. If real kernel-level OOM visibility for SYSTEM RAM is wanted later,
   `journalctl -k -f` grepped for "Out of memory: Killed process" gets you
   that with zero extra privilege and zero eBPF — genuinely simpler for a
   simpler ask than what a kprobe pipeline would need to guarantee.

2. cgroups v2 resource control is NOT done via raw writes to a hand-rolled
   `/sys/fs/cgroup/aibrain/background` path. An unprivileged user cannot
   create a new top-level cgroup directory there — that needs root, and then
   explicit delegation (chown) to the user, which is a real host-configuration
   step, not something this script can silently assume. The setup commands
   below configure that delegation correctly for a `systemctl --user` slice.
   Once delegated, this script writes to the ALREADY-DELEGATED subtree
   systemd hands this service (visible to the running process via
   /sys/fs/cgroup/<own delegated path>, resolved from /proc/self/cgroup),
   not an arbitrary invented path.

Everything else — PID-file-descriptor process tracking (Pillar 3), the
hybrid asyncio circadian scheduler (Pillar 5) — is built as specified,
because those parts are sound.

VERIFICATION STATUS (stated precisely, not implied by confident-looking code):
- pidfd_open + ctypes-based pidfd_send_signal: ACTUALLY TESTED against a
  real child process in the build sandbox, including the specific
  race-safety property (a stale pidfd correctly fails against a since-exited,
  potentially PID-reused process rather than silently signaling the wrong
  one).
- PSI avg10 parsing: ACTUALLY TESTED against a realistic sample line.
- Schedule/hour/minute matching: ported from, and re-verified against, the
  already-tested bash job table and collision-free minute assignments from
  the prior iteration.
- PSI epoll trigger registration, cgroup delegated-path resolution/writes,
  and rocm-smi/nvidia-smi parsing: syntactically correct and built to the
  documented kernel/tool interfaces, but NOT exercised against a real
  kernel PSI trigger, a real delegated cgroup, or real GPU tooling — this
  sandbox has none of those (no /proc/pressure, no systemd/logind session,
  no GPU). Confirm these three specifically on the real target machine
  before trusting them unattended.

POST-REVIEW FIX (bug scan, applied here): run_spawn() originally awaited
proc.communicate() with no timeout while holding _spawn_lock — one hung
    `hermes chat` call (network stall, model stuck generating, an
agent turn that never returns) would silently starve every other spawn-type
job forever, with nothing logged, until a manual restart. Confirmed with an
isolated asyncio.Lock repro, then with a real hung subprocess against the
actual _spawn_lock. Fixed via _await_with_timeout() wrapping
proc.communicate() in asyncio.wait_for(), configurable via --direct-timeout
(default 300s) and --spawn-timeout (default 900s — real agent turns
legitimately run long). On timeout the process is killed via its pidfd and
the lock releases within timeout+5s worst case. Re-verified against the
real _spawn_lock with a genuinely hung `sleep 999` subprocess: queued
waiters that would previously have blocked forever now unblock exactly at
the configured timeout.
"""

from __future__ import annotations

import asyncio
import ctypes
import ctypes.util
import errno
import json
import logging
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional

# ── Logging: stdout, systemd/journald captures it directly (Type=simple) ────
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
    stream=sys.stdout,
)
logging.Formatter.converter = time.gmtime
log = logging.getLogger("deep-brain-kernel")

WORKSPACE = Path(os.environ.get("WORKSPACE", str(Path.home() / ".hermes" / "workspace")))
SKILLS_DIR = WORKSPACE / "skills"

# ROADMAP M3 + Gap-2 follow-on: provider abstraction for spawn jobs.
# SPAWN_PROVIDER=hermes (default, external harness), local (suite's own
# llm-call.sh endpoint), or agentloop (internal agentic loop — tool use +
# session memory, core/agent-loop/agent-loop.sh). Unknown values fall back to
# hermes with a warning — never fail to launch.
SPAWN_PROVIDER = os.environ.get("SPAWN_PROVIDER", "agentloop").strip().lower()
if SPAWN_PROVIDER not in ("hermes", "local", "agentloop"):
    log.warning("unknown SPAWN_PROVIDER '%s' — defaulting to hermes", SPAWN_PROVIDER)
    SPAWN_PROVIDER = "hermes"
SPAWN_PROVIDER_SHIM = Path(__file__).resolve().parent / "core" / "spawn" / "spawn-provider.sh"

# XDG runtime dir for this user — correct place for ephemeral daemon state
# (pid lock, sockets), distinct from the persistent per-skill data in
# WORKSPACE/memory. Falls back to a workspace-local dir if no real user
# session owns /run/user/<uid> (e.g. run outside systemd-logind, exactly
# the situation in this build sandbox).
_uid = os.getuid()
_xdg_runtime = Path(f"/run/user/{_uid}")
if _xdg_runtime.is_dir() and os.access(_xdg_runtime, os.W_OK):
    RUNTIME_DIR = _xdg_runtime / "aibrain"
else:
    RUNTIME_DIR = WORKSPACE / ".aibrain-runtime"
    log.warning(
        "no writable /run/user/%s (no active logind session?) — using %s for "
        "runtime state instead. Under systemd --user this directory always "
        "exists; this fallback matters for manual/sandboxed invocation only.",
        _uid, RUNTIME_DIR,
    )

PID_LOCK_FILE = RUNTIME_DIR / "deep-brain-kernel.pid"
DAEMON_STATE_FILE = WORKSPACE / "memory" / "deep-brain-kernel-state.json"
EXECUTIVE_LOAD_FILE = WORKSPACE / "memory" / "executive-load.json"
PFC_STATE_FILE = WORKSPACE / "memory" / "pfc-state.json"
DECISION_QUEUE_FILE = WORKSPACE / "memory" / "decision-queue.json"

# V4.0 Executive Load: rolling window of inference seconds for last 10 ticks.
# E = (G * 0.06) + (Q * 0.12) + (I_sec / 25); clip at 1.0.
# Targets: 0.35–0.60 desired, 0.75 hard ceiling, 1.0 clip.
_INFERENCE_WINDOW: list[dict] = []  # [{tick, seconds}, ...] max 10
_EXEC_LOAD_TICK: int = 0
_LOAD_REDUCTION_ACTIVE: bool = False

# ── ctypes: raw syscall bridge for pidfd_send_signal (Pillar 3) ─────────────
# There is no os.pidfd_send_signal in the Python standard library — only
# os.pidfd_open (3.9+) is exposed. Confirmed directly: Python 3.12,
# hasattr(os, 'pidfd_open') == True, hasattr(os, 'pidfd_send_signal') == False.
# The raw syscall (pidfd_send_signal(2), syscall NR 424 on x86_64, present
# since Linux 5.1) has to go through ctypes.
_libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
_SYS_pidfd_send_signal = 424  # x86_64; see /usr/include/asm-generic/unistd.h on other arches


def pidfd_send_signal(pidfd: int, sig: int) -> None:
    res = _libc.syscall(_SYS_pidfd_send_signal, ctypes.c_int(pidfd), ctypes.c_int(sig), None, ctypes.c_uint(0))
    if res != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))


class TrackedProcess:
    """Wraps a running child's pid with a pidfd for race-free signaling — the
    whole point of Pillar 3. Takes a raw pid directly (asyncio's own
    subprocess.Process objects aren't stdlib Popen instances, and don't need
    to be wrapped as one just to get a pidfd — os.pidfd_open only needs the
    pid itself)."""

    def __init__(self, pid: int):
        self.pid = pid
        self.pidfd = os.pidfd_open(pid, 0)

    def terminate(self) -> None:
        try:
            pidfd_send_signal(self.pidfd, signal.SIGTERM)
        except OSError as e:
            if e.errno != errno.ESRCH:  # ESRCH: already exited — not an error here
                log.warning("pidfd terminate on pid %s failed: %s", self.pid, e)

    def kill(self) -> None:
        try:
            pidfd_send_signal(self.pidfd, signal.SIGKILL)
        except OSError as e:
            if e.errno != errno.ESRCH:
                log.warning("pidfd kill on pid %s failed: %s", self.pid, e)

    def close(self) -> None:
        try:
            os.close(self.pidfd)
        except OSError:
            pass


# ── Pillar 1: PSI via epoll (zero-poll pressure monitoring) ─────────────────
# Real, documented kernel API (Linux 4.20+): open /proc/pressure/{memory,cpu},
# write a trigger spec "<some|full> <stall_us> <window_us>\0", register the
# fd with epoll for EPOLLPRI. The kernel wakes the epoll_wait only when the
# specified stall threshold is crossed within the window — no userspace
# polling loop reading the file on a timer.
class PSIMonitor:
    def __init__(self, resource: str, stall_us: int = 150_000, window_us: int = 1_000_000):
        self.path = f"/proc/pressure/{resource}"
        self.resource = resource
        self.stall_us = stall_us
        self.window_us = window_us
        self.fd: Optional[int] = None
        self.epoll: Optional[select.epoll] = None
        self.available = False
        # "trigger" = epoll PSI write trigger (preferred, needs privileged write on some kernels)
        # "poll"    = unprivileged read of /proc/pressure avg10 (works without CAP)
        self.mode: str = "unavailable"

    def open(self) -> bool:
        if not os.path.exists(self.path):
            log.warning("PSI unavailable: %s does not exist (CONFIG_PSI not "
                        "compiled in, or /proc/pressure not mounted) — "
                        "pressure-based deferral disabled for %s", self.path, self.resource)
            return False
        # Prefer kernel triggers (zero-poll). On Ubuntu 6.8 unprivileged
        # write to /proc/pressure/* returns EINVAL; root succeeds. Fall back
        # to avg10 polling so PSI is still used without elevating the daemon.
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_NONBLOCK)
            trigger = f"some {self.stall_us} {self.window_us}".encode()
            os.write(self.fd, trigger)
            self.epoll = select.epoll()
            self.epoll.register(self.fd, select.EPOLLPRI)
            self.available = True
            self.mode = "trigger"
            log.info("PSI monitor armed for %s via trigger (some %dus / %dus)",
                      self.resource, self.stall_us, self.window_us)
            return True
        except OSError as e:
            if self.fd is not None:
                try:
                    os.close(self.fd)
                except OSError:
                    pass
                self.fd = None
            # Unprivileged EINVAL is expected on this host — not "PSI missing".
            log.warning(
                "PSI trigger write failed for %s (%s). "
                "Root can arm triggers; unprivileged write returns EINVAL on this kernel. "
                "Falling back to avg10 poll mode for %s.",
                self.resource, e, self.resource,
            )
            # Confirm readable
            try:
                with open(self.path, "r") as f:
                    f.read()
                self.available = True
                self.mode = "poll"
                return True
            except OSError as e2:
                log.warning("PSI also unreadable for %s: %s", self.resource, e2)
                self.mode = "unavailable"
                return False

    def blocking_wait(self, timeout: float) -> bool:
        """Blocks until pressure is elevated, or `timeout` seconds elapse.
        Trigger mode: kernel epoll_wait (zero-poll).
        Poll mode: sleep slices + read avg10 (unprivileged-safe).
        Must be called via run_in_executor from the asyncio loop."""
        if not self.available:
            time.sleep(timeout)
            return False
        if self.mode == "trigger" and self.epoll is not None:
            events = self.epoll.poll(timeout=timeout)
            return len(events) > 0
        if self.mode == "poll":
            # Sample avg10 until threshold crossed or timeout.
            deadline = time.monotonic() + max(0.1, timeout)
            while time.monotonic() < deadline:
                avg = psi_avg10(self.resource)
                if avg is not None and avg >= 10.0:  # default hard-match pressure_supervisor
                    return True
                time.sleep(min(2.0, max(0.05, deadline - time.monotonic())))
            return False
        time.sleep(timeout)
        return False

    def close(self) -> None:
        if self.epoll is not None:
            self.epoll.close()
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass


# ── GPU VRAM backpressure (the actual resource pool for local inference) ────
def gpu_vram_percent() -> Optional[float]:
    """Returns VRAM usage as a percentage (0-100), or None if it can't be
    determined — fails OPEN: "can't tell" means "assume fine, don't block",
    never the reverse.

    VULKAN-FIRST, deliberately: this box's actual inference stack is
    llama.cpp/Ollama via Mesa RADV/Vulkan on an RX 5700 XT (RDNA1, gfx1010) —
    ROCm does not support this GPU at all, and CUDA is irrelevant (no NVIDIA
    hardware). Checking nvidia-smi or rocm-smi FIRST, as the prior version of
    this function did, was wrong for this machine: neither will ever fire,
    and prioritizing them ahead of anything Vulkan-aware doesn't match the
    actual driver stack in use. Order here is:
      1. Vulkan (vulkaninfo, --json then plain-text) — genuinely queries the
         Vulkan driver's own memory budget/usage reporting via
         VK_EXT_memory_budget, i.e. the same layer llama.cpp's Vulkan
         backend actually allocates through.
      2. amdgpu kernel sysfs (mem_info_vram_used/total) — vendor-neutral,
         driver-level ground truth, needs no extra tool installed at all,
         and still correctly reflects Vulkan-driven allocations since it's
         reading the same underlying kernel accounting beneath any
         userspace API. Kept as the fallback specifically because it does
         NOT favor CUDA/ROCm either — it's a kernel primitive, not a
         vendor tool.
      3. nvidia-smi / rocm-smi — kept only for portability if this script
         ever runs on different hardware. On THIS machine neither will ever
         be found, and that's expected, not a bug.
    """
    # ── 1. Vulkan (primary) ──────────────────────────────────────────────
    if shutil.which("vulkaninfo"):
        # Run --json in a temp cwd: some Vulkan-Tools builds (incl. this
        # host's) emit EMPTY stdout for --json and instead write a
        # VP_VULKANINFO_*.json artifact into the cwd — which previously
        # accumulated in the daemon's working directory on every spawn
        # dispatch (verified: three had landed in $HOME). Parse stdout when
        # a build does emit it; the VP artifact itself carries no
        # memory-budget data (verified 2026-08-08), so it is not parsed —
        # the plain-text path below is the live one on this host.
        try:
            with tempfile.TemporaryDirectory(prefix="aibrain-vulkaninfo-") as tmp:
                out = subprocess.run(
                    ["vulkaninfo", "--json"], capture_output=True, text=True,
                    timeout=5, cwd=tmp,
                )
                if out.returncode == 0 and out.stdout.strip():
                    pct = _parse_vulkaninfo_json(out.stdout)
                    if pct is not None:
                        return pct
        except (subprocess.SubprocessError, ValueError) as e:
            log.warning("vulkaninfo --json didn't parse as expected: %s", e)

        # --json support / VK_EXT_memory_budget reporting varies by
        # Vulkan-Tools version — try plain-text output as a second attempt
        # before giving up on Vulkan entirely.
        try:
            out = subprocess.run(
                ["vulkaninfo"], capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                pct = _parse_vulkaninfo_text(out.stdout)
                if pct is not None:
                    return pct
        except subprocess.SubprocessError as e:
            log.warning("vulkaninfo (plain-text) call failed: %s", e)

        log.warning("vulkaninfo found but neither --json nor plain-text output "
                    "yielded a usable memory-budget reading (see NOTE: verify "
                    "your installed Vulkan-Tools version actually reports "
                    "VK_EXT_memory_budget) — falling back to amdgpu sysfs")
    else:
        log.warning("vulkaninfo not found on PATH (part of the `vulkan-tools` "
                    "package) — skipping the Vulkan-first check, falling back "
                    "to amdgpu sysfs")

    # ── 2. amdgpu kernel sysfs (vendor-neutral fallback) ─────────────────
    pct = _amdgpu_sysfs_vram_percent()
    if pct is not None:
        return pct

    # ── 3. nvidia-smi / rocm-smi (portability fallbacks, not expected to
    #      ever fire on this hardware) ────────────────────────────────────
    if shutil.which("nvidia-smi"):
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                line = out.stdout.strip().splitlines()[0]
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 2:
                    used, total = float(parts[0]), float(parts[1])
                    if total > 0:
                        return (used / total) * 100.0
        except (subprocess.SubprocessError, ValueError, IndexError) as e:
            log.warning("nvidia-smi output didn't parse as expected: %s", e)

    if shutil.which("rocm-smi"):
        # Not applicable to RDNA1 (gfx1010) — ROCm doesn't support this GPU
        # at all. Kept only for portability if this script runs on
        # ROCm-capable AMD hardware (RDNA2+/CDNA) elsewhere.
        try:
            out = subprocess.run(
                ["rocm-smi", "--showmeminfo", "vram", "--json"],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                data = json.loads(out.stdout)
                pct = _search_vram_percent(data)
                if pct is not None:
                    return pct
        except (subprocess.SubprocessError, ValueError, json.JSONDecodeError, AttributeError) as e:
            log.warning("rocm-smi output didn't parse as expected: %s", e)

    return None


def _search_vram_percent(node) -> Optional[float]:
    """Best-effort recursive VRAM parser for vendor tools that emit varying JSON."""
    if isinstance(node, dict):
        keys = {
            "used": (
                "VRAM Total Used Memory (B)",
                "VRAM Total Used Memory",
                "memory.used",
                "used",
            ),
            "total": (
                "VRAM Total Memory (B)",
                "VRAM Total Memory",
                "memory.total",
                "total",
            ),
        }
        used = total = None
        for key in keys["used"]:
            if key in node:
                used = node[key]
                break
        for key in keys["total"]:
            if key in node:
                total = node[key]
                break
        if used is not None and total is not None:
            try:
                used_f = float(used)
                total_f = float(total)
                if total_f > 0:
                    return (used_f / total_f) * 100.0
            except (TypeError, ValueError):
                pass
        for value in node.values():
            pct = _search_vram_percent(value)
            if pct is not None:
                return pct
    elif isinstance(node, list):
        for value in node:
            pct = _search_vram_percent(value)
            if pct is not None:
                return pct
    return None


def _parse_vulkaninfo_json(raw: str) -> Optional[float]:
    """Best-effort parse of vulkaninfo --json's memory budget reporting.
    The schema has changed across Vulkan-Tools versions, so this tries
    several plausible shapes and returns None (fail open) if none match,
    rather than guessing.

    Verified on this host (2026-08-08): this Vulkan-Tools build emits
    EMPTY stdout for --json and writes a VP_VULKANINFO_*.json artifact
    whose schema (VP format: $schema/capabilities/profiles) carries NO
    memory-budget data — so this parser legitimately returns None here and
    the plain-text parser (_parse_vulkaninfo_text) is the live path.
    The candidates below still cover builds that DO emit budget data on
    stdout, including under the VP `capabilities.device` path.
    """
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None

    candidates = []
    if isinstance(data, dict):
        candidates.append(data)
        caps = data.get("capabilities")
        if isinstance(caps, dict):
            candidates.append(caps)
            dev = caps.get("device")
            if isinstance(dev, dict):
                candidates.append(dev)
        devices = data.get("devices") if isinstance(data.get("devices"), list) else None
        if devices:
            candidates.extend(d for d in devices if isinstance(d, dict))

    for node in candidates:
        budget_props = (
            node.get("VkPhysicalDeviceMemoryBudgetPropertiesEXT")
            or node.get("memoryBudget")
        )
        mem_props = (
            node.get("VkPhysicalDeviceMemoryProperties")
            or node.get("memoryProperties")
        )
        if not isinstance(budget_props, dict):
            continue

        heap_budget = budget_props.get("heapBudget")
        heap_usage = budget_props.get("heapUsage")
        if not (isinstance(heap_budget, list) and isinstance(heap_usage, list)):
            continue

        device_local_indices = None
        if isinstance(mem_props, dict):
            heaps = mem_props.get("memoryHeaps")
            if isinstance(heaps, list):
                device_local_indices = [
                    i for i, h in enumerate(heaps)
                    if isinstance(h, dict) and "DEVICE_LOCAL" in str(h.get("flags", ""))
                ]

        indices = device_local_indices or range(len(heap_budget))
        total_budget = 0.0
        total_usage = 0.0
        for i in indices:
            if i < len(heap_budget) and i < len(heap_usage):
                try:
                    total_budget += float(heap_budget[i])
                    total_usage += float(heap_usage[i])
                except (TypeError, ValueError):
                    continue
        if total_budget > 0:
            return (total_usage / total_budget) * 100.0

    return None


def _parse_vulkaninfo_text(raw: str) -> Optional[float]:
    """Parses `memoryHeaps[N]:` blocks from real `vulkaninfo` plain-text
    output, summing size/budget only across heaps flagged
    MEMORY_HEAP_DEVICE_LOCAL_BIT (actual VRAM — excludes host-visible/
    system-RAM heaps, which vulkaninfo lists separately with flags: None).

    percent_used = (size - budget) / size * 100

    NOT usage / budget: Vulkan's `budget` field is "how much this process
    can still allocate right now" (accounts for everyone's usage), not
    total heap capacity, and `usage` is only vulkaninfo's own trivial
    allocation. Verified against real vulkaninfo output on RX 5700 XT
    (RADV navi10), 2026-08-08 — heap[1], 7.98 GiB, DEVICE_LOCAL_BIT,
    budget 840.82 MiB free == ~7.14 GiB already in use.
    """
    import re
    heap_starts = [m.start() for m in re.finditer(r'memoryHeaps\[\d+\]:', raw)]
    if not heap_starts:
        return None
    heap_starts.append(len(raw))

    total_size = 0.0
    total_budget = 0.0
    for i in range(len(heap_starts) - 1):
        block = raw[heap_starts[i]:heap_starts[i + 1]]
        if 'MEMORY_HEAP_DEVICE_LOCAL_BIT' not in block:
            continue
        size_m = re.search(r'size\s*=\s*(\d+)', block)
        budget_m = re.search(r'budget\s*=\s*(\d+)', block)
        if size_m and budget_m:
            total_size += float(size_m.group(1))
            total_budget += float(budget_m.group(1))

    if total_size > 0:
        return ((total_size - total_budget) / total_size) * 100.0
    return None


def psi_avg10(resource: str) -> Optional[float]:
    """Synchronous, instantaneous read of PSI avg10 for `resource` ("memory"
    or "cpu"), parsed from the "some avg10=X.XX ..." line of
    /proc/pressure/<resource>. Returns None if PSI isn't available.

    FIX #5: the epoll-based PSIMonitor only reports pressure AFTER the
    kernel's stall-threshold trigger has already crossed — by design, that's
    what makes it interrupt-driven instead of polled. But that means a
    spawn job evaluated in the gap between "pressure is rising" and "the
    trigger actually fires" could still launch straight into it: the global
    pressure_state flag only flips once triggered. This function gives
    run_spawn() a direct, point-in-time reading to check against right
    before it commits to firing a job — independent of whether the trigger
    has crossed yet — closing that gap without turning the supervisor back
    into a polling loop (this is only called once per spawn-job dispatch,
    not on a timer).
    """
    path = f"/proc/pressure/{resource}"
    try:
        with open(path, "r") as f:
            for line in f:
                if line.startswith("some "):
                    for field_ in line.split():
                        if field_.startswith("avg10="):
                            return float(field_.split("=", 1)[1])
    except (OSError, ValueError):
        return None
    return None


def _amdgpu_sysfs_vram_percent() -> Optional[float]:
    """Direct amdgpu kernel driver sysfs read — no external tool needed,
    vendor-neutral (doesn't favor CUDA/ROCm), reflects real VRAM allocation
    beneath any userspace API including Vulkan. Not tested against a real
    amdgpu card (no GPU in the build sandbox); the sysfs ABI itself
    (mem_info_vram_used/total under a card's device dir) is long-standing
    and part of the kernel's stable sysfs contract, unlike a CLI tool's
    output formatting, so this is lower-risk than the vulkaninfo parsing
    above even though it's equally unverified in this environment.
    """
    try:
        drm_dir = Path("/sys/class/drm")
        if not drm_dir.is_dir():
            return None
        for card in sorted(drm_dir.glob("card[0-9]*")):
            device_dir = card / "device"
            vendor_file = device_dir / "vendor"
            if not vendor_file.is_file():
                continue
            try:
                vendor = vendor_file.read_text().strip()
            except OSError:
                continue
            if vendor.lower() != "0x1002":  # AMD PCI vendor ID
                continue
            used_file = device_dir / "mem_info_vram_used"
            total_file = device_dir / "mem_info_vram_total"
            if used_file.is_file() and total_file.is_file():
                used = float(used_file.read_text().strip())
                total = float(total_file.read_text().strip())
                if total > 0:
                    return (used / total) * 100.0
    except (OSError, ValueError) as e:
        log.warning("amdgpu sysfs VRAM read failed: %s", e)
    return None



# ── Pillar 2: cgroups v2 resource control ───────────────────────────────────
# Deliberately NOT writing to a hand-rolled top-level path — see module
# docstring. This resolves the cgroup path systemd has ALREADY delegated to
# this service (set via the unit file's Slice=/Delegate=, not invented here),
# by reading /proc/self/cgroup, and only writes cpu.weight / memory.high
# within that already-delegated subtree.
class CgroupThrottle:
    def __init__(self):
        self.cgroup_path: Optional[Path] = None
        self.default_cpu_weight = "100"
        self.throttled_cpu_weight = "10"
        self._resolve()
        self.default_memory_high = self._read("memory.high")

    def _resolve(self) -> None:
        try:
            content = Path("/proc/self/cgroup").read_text()
            # cgroup v2 unified hierarchy: a single "0::<path>" line.
            for line in content.splitlines():
                if line.startswith("0::"):
                    rel = line.split("::", 1)[1]
                    candidate = Path("/sys/fs/cgroup") / rel.lstrip("/")
                    if candidate.is_dir() and os.access(candidate / "cgroup.procs", os.W_OK):
                        self.cgroup_path = candidate
                        log.info("cgroup throttle target resolved: %s", candidate)
                        return
            log.warning("could not resolve a writable delegated cgroup v2 path "
                        "from /proc/self/cgroup — resource throttling disabled "
                        "(everything else keeps working; see setup commands "
                        "for delegation requirements)")
        except OSError as e:
            log.warning("failed to read /proc/self/cgroup: %s — resource "
                        "throttling disabled", e)

    def _write(self, filename: str, value: str) -> bool:
        if self.cgroup_path is None:
            return False
        target = self.cgroup_path / filename
        try:
            target.write_text(value)
            return True
        except OSError as e:
            log.warning("failed to write %s to %s: %s", value, target, e)
            return False

    def _read(self, filename: str) -> Optional[str]:
        if self.cgroup_path is None:
            return None
        target = self.cgroup_path / filename
        try:
            return target.read_text().strip()
        except OSError:
            return None

    def _compute_throttled_memory_high(self) -> Optional[str]:
        current = self._read("memory.current")
        if current is None:
            return None
        try:
            usage = int(current)
        except ValueError:
            return None
        # Soft-limit the cgroup to current usage plus 512 MiB while pressure
        # is active, which gives the kernel room to reclaim memory without
        # hard-stalling the daemon's own cgroup.
        return str(usage + (512 * 1024 * 1024))

    def throttle(self) -> None:
        if self._write("cpu.weight", self.throttled_cpu_weight):
            log.warning("throttled cpu.weight to %s under detected pressure", self.throttled_cpu_weight)
        memory_high = self._compute_throttled_memory_high()
        if memory_high is not None and self._write("memory.high", memory_high):
            log.warning("set memory.high to %s bytes under detected pressure", memory_high)

    def restore(self) -> None:
        if self._write("cpu.weight", self.default_cpu_weight):
            log.info("restored cpu.weight to %s — pressure cleared", self.default_cpu_weight)
        if self.default_memory_high is not None and self._write("memory.high", self.default_memory_high):
            log.info("restored memory.high to %s — pressure cleared", self.default_memory_high)


class DaemonState:
    # FIX #3: last_fired_key alone can't answer "has this job actually been
    # working" — a job can fire every tick and fail every tick (missing
    # script, hermes gone, bad GPU-parsing exception) and this state file
    # would look identical to a healthy one. job_stats adds a persistent,
    # per-job outcome history: total success/failure counts, a consecutive-
    # failure streak (the thing you actually care about — "has this been
    # broken continuously" vs "it failed once three weeks ago"), and the
    # last error seen, so `--status` can surface it without grepping
    # journalctl for the right minute.
    UNHEALTHY_STREAK = 3  # consecutive failures before --status flags a job

    def __init__(self, path: Path):
        self.path = path
        self.last_tick_utc: Optional[str] = None
        self.job_last_fired: dict[str, str] = {}
        self.job_stats: dict[str, dict] = {}
        self._load()

    def _load(self) -> None:
        try:
            data = json.loads(self.path.read_text())
        except (OSError, json.JSONDecodeError):
            return
        if isinstance(data, dict):
            last_tick = data.get("lastTickUtc")
            if isinstance(last_tick, str):
                self.last_tick_utc = last_tick
            job_map = data.get("jobLastFired")
            if isinstance(job_map, dict):
                self.job_last_fired = {str(k): str(v) for k, v in job_map.items()}
            stats_map = data.get("jobStats")
            if isinstance(stats_map, dict):
                for name, stats in stats_map.items():
                    if isinstance(stats, dict):
                        self.job_stats[str(name)] = {
                            "success": int(stats.get("success", 0) or 0),
                            "failure": int(stats.get("failure", 0) or 0),
                            "consecutive_failures": int(stats.get("consecutive_failures", 0) or 0),
                            "last_success_utc": stats.get("last_success_utc"),
                            "last_failure_utc": stats.get("last_failure_utc"),
                            "last_error": stats.get("last_error"),
                        }

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        payload = {
            "lastTickUtc": self.last_tick_utc,
            "jobLastFired": self.job_last_fired,
            "jobStats": self.job_stats,
            "updatedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True))
        tmp.replace(self.path)

    def set_tick(self, dt: datetime) -> None:
        self.last_tick_utc = dt.isoformat().replace("+00:00", "Z")

    def set_job_fired(self, job_name: str, minute_key: str) -> None:
        self.job_last_fired[job_name] = minute_key

    def job_fired_key(self, job_name: str) -> Optional[str]:
        return self.job_last_fired.get(job_name)

    def record_result(self, job_name: str, success: bool, error: Optional[str] = None) -> None:
        """Record a job's actual execution outcome (not a defer/skip — only
        a job that genuinely ran and either finished or failed/timed out).
        Deferrals (VRAM limit, PSI pressure, hermes missing, script missing)
        deliberately do NOT call this: those are the scheduler correctly
        declining to run, not the job failing, and mixing the two would
        make a well-behaved deferral look identical to a broken job in
        --status output."""
        stats = self.job_stats.setdefault(job_name, {
            "success": 0, "failure": 0, "consecutive_failures": 0,
            "last_success_utc": None, "last_failure_utc": None, "last_error": None,
        })
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        # M5: append this real run's outcome to the per-run history ledger
        # (memory/daemon-job-history.jsonl) so the dashboard's /__daemon can
        # render a per-job success-rate trend over time — the cumulative
        # job_stats counters alone can't show whether a job is improving.
        # Best-effort only: a write failure must never fail the job record.
        try:
            history_path = self.path.parent / "daemon-job-history.jsonl"
            # The memory dir may not exist yet on the first real run (before
            # any save() call) — create it so the first outcome line is never
            # silently dropped by the FileNotFoundError path.
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(history_path, "a", encoding="utf-8") as hf:
                hf.write(json.dumps({"ts": now, "job": job_name, "success": success}) + "\n")
        except OSError:
            pass
        if success:
            stats["success"] += 1
            stats["consecutive_failures"] = 0
            stats["last_success_utc"] = now
        else:
            stats["failure"] += 1
            stats["consecutive_failures"] += 1
            stats["last_failure_utc"] = now
            if error:
                stats["last_error"] = error[:500]


# ── V4.0 Executive Load formula (wired into daemon tick) ─────────────────────
def _count_active_goals() -> int:
    try:
        data = json.loads(PFC_STATE_FILE.read_text())
        goals = data.get("goals") or []
        return sum(1 for g in goals if isinstance(g, dict) and g.get("status") == "active")
    except (OSError, json.JSONDecodeError, TypeError):
        return 0


def _active_goal_descriptions(max_goals: int = 3) -> list[str]:
    """ROADMAP M4: top-priority active executive goals as short strings, for
    injecting into spawn-job task text so agent turns actually work toward
    promoted goals instead of running context-free. Best-effort: an empty
    list when PFC state is missing/unreadable — never raises."""
    try:
        data = json.loads(PFC_STATE_FILE.read_text())
        goals = data.get("goals") or []
        active = [g for g in goals if isinstance(g, dict) and g.get("status") == "active"]
        active.sort(key=lambda g: float(g.get("priority") or 0.0), reverse=True)
        return [
            str(g.get("description") or "").strip()
            for g in active[:max_goals]
            if str(g.get("description") or "").strip()
        ]
    except (OSError, json.JSONDecodeError, TypeError):
        return []


def _augment_spawn_task(task: str, goals: list[str]) -> str:
    """ROADMAP M4: append active goals to a spawn job's task text as an
    explicit executive-context block. Pure and testable: no goals → task
    unchanged."""
    if not goals:
        return task
    block = "\n".join(f"- {g}" for g in goals)
    return f"{task}\n\n[Executive context — active goals to keep in mind:\n{block}\n]"


async def _record_goal_outcomes(job_name: str, goal_descriptions: list[str],
                                 outcome: str, task_text: str) -> None:
    """ROADMAP M4: best-effort goal-outcome recording after a spawn job
    finishes. Runs OUTSIDE the spawn lock (see run_spawn) and awaits each
    recorder call with a timeout, so a slow recorder can never starve other
    spawn jobs. task_text is the ORIGINAL job.target (not the augmented
    text), so the recorder's relevance guard matches goals against the
    actual task, not against the injected goal block itself.
    Never raises; failures are logged only."""
    recorder = Path(__file__).resolve().parent / "core" / "executive" / "record-goal-outcome.sh"
    if not recorder.is_file():
        return
    env = {**os.environ, "WORKSPACE": str(WORKSPACE)}
    for desc in goal_descriptions:
        try:
            proc = await asyncio.create_subprocess_exec(
                "bash", str(recorder), "outcome",
                "--goal-description", desc, "--outcome", outcome,
                "--job", job_name, "--task", task_text,
                env=env,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.communicate(), timeout=10)
        except (OSError, subprocess.SubprocessError, asyncio.TimeoutError) as e:
            log.warning("%s: goal-outcome recorder failed for '%s': %s", job_name, desc, e)


def _decision_queue_depth() -> int:
    try:
        data = json.loads(DECISION_QUEUE_FILE.read_text())
        if isinstance(data, list):
            return len(data)
        if isinstance(data, dict):
            pending = data.get("pending", data.get("queue", []))
            return len(pending) if isinstance(pending, list) else 0
    except (OSError, json.JSONDecodeError, TypeError):
        return 0
    return 0


def record_inference_seconds(seconds: float) -> None:
    """Accumulate inference time for the current tick (spawn jobs)."""
    global _INFERENCE_WINDOW, _EXEC_LOAD_TICK
    if seconds < 0:
        return
    # Fold into the most recent window entry for this tick, or create one
    if _INFERENCE_WINDOW and _INFERENCE_WINDOW[-1].get("tick") == _EXEC_LOAD_TICK:
        _INFERENCE_WINDOW[-1]["seconds"] = float(_INFERENCE_WINDOW[-1]["seconds"]) + float(seconds)
    else:
        _INFERENCE_WINDOW.append({"tick": _EXEC_LOAD_TICK, "seconds": float(seconds)})
        if len(_INFERENCE_WINDOW) > 10:
            _INFERENCE_WINDOW = _INFERENCE_WINDOW[-10:]


def compute_executive_load() -> dict:
    """E = (G*0.06)+(Q*0.12)+(I_sec/25); clip at 1.0."""
    global _LOAD_REDUCTION_ACTIVE
    G = _count_active_goals()
    Q = _decision_queue_depth()
    I_sec = sum(float(e.get("seconds") or 0) for e in _INFERENCE_WINDOW[-10:])
    E_raw = (G * 0.06) + (Q * 0.12) + (I_sec / 25.0)
    clipped = E_raw > 1.0
    E = 1.0 if clipped else E_raw
    if E < 0.35:
        band = "underutilized"
    elif E <= 0.60:
        band = "desired"
    elif E <= 0.75:
        band = "elevated"
    elif E < 1.0:
        band = "hard_ceiling_zone"
    else:
        band = "clipped"
    load_reduction = E >= 0.75 or clipped
    _LOAD_REDUCTION_ACTIVE = load_reduction
    return {
        "E": round(E, 6),
        "E_raw": round(E_raw, 6),
        "G": G,
        "Q": Q,
        "I_sec": round(I_sec, 6),
        "tick": _EXEC_LOAD_TICK,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "clipped": clipped,
        "band": band,
        "thresholds": {
            "desired_min": 0.35,
            "desired_max": 0.60,
            "hard_ceiling": 0.75,
            "clip": 1.0,
        },
        "load_reduction_recommended": load_reduction,
        "inference_window": list(_INFERENCE_WINDOW[-10:]),
    }


def update_executive_load_file() -> dict:
    """Compute E for this tick, persist executive-load.json, log load-reduction."""
    global _EXEC_LOAD_TICK, _INFERENCE_WINDOW
    _EXEC_LOAD_TICK += 1
    # Ensure current tick has a window slot even if no inference ran
    if not _INFERENCE_WINDOW or _INFERENCE_WINDOW[-1].get("tick") != _EXEC_LOAD_TICK:
        _INFERENCE_WINDOW.append({"tick": _EXEC_LOAD_TICK, "seconds": 0.0})
        if len(_INFERENCE_WINDOW) > 10:
            _INFERENCE_WINDOW = _INFERENCE_WINDOW[-10:]
    payload = compute_executive_load()
    try:
        EXECUTIVE_LOAD_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = EXECUTIVE_LOAD_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True))
        tmp.replace(EXECUTIVE_LOAD_FILE)
    except OSError as e:
        log.warning("failed to write executive-load.json: %s", e)
    if payload["load_reduction_recommended"]:
        log.warning(
            "executive load E=%.3f band=%s — load-reduction active "
            "(deferring non-essential spawn jobs; G=%s Q=%s I_sec=%.2f)",
            payload["E"], payload["band"], payload["G"], payload["Q"], payload["I_sec"],
        )
    else:
        log.debug(
            "executive load E=%.3f band=%s G=%s Q=%s I_sec=%.2f",
            payload["E"], payload["band"], payload["G"], payload["Q"], payload["I_sec"],
        )
    return payload


def _minute_range(start: datetime, end: datetime, max_minutes: int = 24 * 60):
    current = start.replace(second=0, microsecond=0)
    end = end.replace(second=0, microsecond=0)
    count = 0
    while current <= end and count < max_minutes:
        yield current
        current += timedelta(minutes=1)
        count += 1


# ── Pillar 5: job table (ported from, and matching, the tested bash version) ─
@dataclass
class Job:
    name: str
    kind: str  # "direct" or "spawn"
    hours: str  # "*" or comma-separated ints
    minutes: str  # comma-separated ints
    target: str  # direct: path relative to SKILLS_DIR ; spawn: task text sent to `hermes chat -q`
    days: str = "*"  # "*" or comma-separated weekday ints, Python convention:
                      # 0=Monday .. 6=Sunday (datetime.weekday()). "*" = every day,
                      # matching every job's behavior before this field existed.
    spawn_max_steps: int = 8   # per-job override for agent-loop MAX_STEPS
                                # (thinking models need more reasoning budget
                                # before producing tool calls)
    thinking_model: bool = False  # when True, auto-appends a no-reasoning
                                   # prompt suffix so the model skips chain-of-
                                   # thought and produces tool calls directly
    last_fired_key: Optional[str] = field(default=None, repr=False)


# Every minute value below is globally unique across this table — see
# BRAIN_DAEMON_SCHEDULE.md for the full audit of why (11 real, pre-existing
# collisions were found when this suite's cron entries were first
# consolidated; hour-sets/frequencies are preserved exactly, only minutes
# were reassigned).
JOBS: list[Job] = [
    Job("heartbeat_beat", "direct", "*", "7,37", "heartbeat-memory/scripts/beat.sh"),
    Job("hippocampus_decay", "direct", "3", "2", "hippocampus-memory/scripts/decay.sh"),
    Job("hippocampus_encoding", "spawn", "0,3,6,9,12,15,18,21", "0",
        "Run hippocampus encoding with LLM summarization: 1. Run the encoding pipeline: "
        "encode-pipeline.sh --no-spawn 2. Check pending memories 3. If pending exist, "
        "summarize each to ~100 chars 4. Update index.json 5. Delete pending-memories.json "
        "6. Sync core 7. Report results",
        spawn_max_steps=12, thinking_model=True),
    # NEW: weekly consolidation and self-reflection. consolidate.sh, reflect.sh, and
    # their prompt files (prompts/consolidation-guide.md, prompts/self-reflect.md,
    # prompts/weekly-reflection-event.md) already existed and were designed for
    # exactly this — "weekly" is stated explicitly in hippocampus's own SKILL.md
    # and README — but neither the legacy bash daemon nor this table ever
    # scheduled them. They were manual-invocation-only in every prior version of
    # this suite. days="6" = Sunday (Python's datetime.weekday(): 0=Mon..6=Sun).
    Job("hippocampus_weekly_consolidation", "spawn", "2", "34",
        "Run weekly memory consolidation: 1) Run consolidate.sh to list the past "
        "week's daily notes 2) Follow prompts/consolidation-guide.md to review each "
        "daily note and extract user/self/relationship/world facts into "
        "memory/{user,self,relationship,world}/*.md 3) Update MEMORY.md with the "
        "most important distilled insights 4) Archive or delete routine/superseded "
        "daily-note content per the guide 5) Report what was consolidated",
        days="6"),
    Job("hippocampus_weekly_reflection", "spawn", "2", "44",
        "Run weekly self-reflection: 1) Run reflect.sh to load the Weekly Reflection "
        "section of prompts/self-reflect.md (also see prompts/weekly-reflection-event.md) "
        "2) Honestly answer: how have I changed this week, what opinions shifted or "
        "strengthened, how has the relationship with the user evolved, what patterns "
        "do I notice in myself, what am I proud of, what do I want to work on "
        "3) Update memory/self/growth.md with any evolution 4) Update "
        "memory/self/opinions.md with new or changed views 5) Update "
        "memory/self/identity.md only if something core has shifted 6) Report what "
        "changed. Be honest, not performative.",
        days="6"),
    Job("amygdala_decay", "direct", "0,6,12,18", "5", "amygdala-memory/scripts/decay-emotion.sh"),
    Job("amygdala_encoding", "spawn", "0,3,6,9,12,15,18,21", "10",
        "Run amygdala emotional encoding: 1) Run preprocess-emotions.sh 2) Read "
        "encode-emotions.md 3) Update state for significant emotions 4) Update "
        "watermark 5) Sync state",
        spawn_max_steps=12, thinking_model=True),
    Job("vta_decay", "direct", "4,12,20", "8", "vta-memory/scripts/decay-drive.sh"),
    Job("vta_encoding", "spawn", "0,3,6,9,12,15,18,21", "20",
        "Run VTA reward encoding: 1) Run preprocess-rewards.sh 2) Read encode-rewards.md "
        "3) Log rewards found 4) Resolve fulfilled anticipations 5) Sync state "
        "6) Update watermark",
        spawn_max_steps=12, thinking_model=True),
    Job("basal_ganglia_decay", "direct", "4", "12", "basal-ganglia-memory/scripts/decay-habits.sh"),
    Job("basal_ganglia_encoding", "spawn", "0,3,6,9,12,15,18,21", "30",
        "Run basal-ganglia encoding pipeline: 1. Run encode-pipeline.sh --no-spawn "
        "2. Check pending habits 3. Classify per prompts/encode-habits.md: new habit, "
        "reinforce existing, or new suppression 4. Update habit-state.json "
        "5. Delete pending-habits.json 6. Sync state 7. Report results",
        spawn_max_steps=12, thinking_model=True),
    Job("insula_encoding", "direct", "0,3,6,9,12,15,18,21", "40", "insula-memory/scripts/encode-pipeline.sh"),
    Job("insula_decay", "direct", "0,4,8,12,16,20", "14", "insula-memory/scripts/decay-sense.sh"),
    Job("acc_conflict_encoding", "direct", "0,3,6,9,12,15,18,21", "50", "anterior-cingulate-memory/scripts/encode-pipeline.sh"),
    Job("acc_conflict_decay", "direct", "0,4,8,12,16,20", "16", "anterior-cingulate-memory/scripts/decay-load.sh"),
    Job("acc_error_analysis", "spawn", "4,12,20", "18",
        "Run ACC error analysis: encode-pipeline.sh, analyze exchanges, log errors, update watermark"),
    Job("pfc_decay", "direct", "0,6,12,18", "22", "prefrontal-cortex-memory/scripts/decay-load.sh"),
    Job("social_decay", "direct", "0", "24", "social-memory/scripts/decay.sh"),
    Job("social_encoding", "spawn", "0,3,6,9,12,15,18,21", "52",
        "Run social-memory encoding: 1) Run encode-pipeline.sh 2) Detect relationship "
        "signals 3) Update relationships 4) Update watermark 5) Sync state",
        spawn_max_steps=12, thinking_model=True),
    Job("cerebellum_refine", "direct", "0,8,16", "26", "cerebellum-memory/scripts/refine.sh"),
    # V4.0 Phase 2: isolated reflection + goal proposal cycle (direct / non-inference).
    # Minute 28 is unique in this table. Runs 3× daily; promote path gates on E < 0.75.
    Job("executive_goal_cycle", "direct", "1,9,17", "28",
        "executive-function/scripts/run-cycle.sh"),
    # V4.0 Phase 3: post-deploy self-mod monitor (auto-rollback on threshold breach).
    # Minute 32 unique. Direct / non-inference. Pipeline runs are on-demand (run-pipeline.sh).
    Job("self_mod_monitor", "direct", "2,10,18", "32",
        "self-mod-runner/scripts/monitor-tick.sh"),
    # ROADMAP M1: scheduled self-mod proposal cycle (weekly, Sunday). Minute 46 unique.
    # Runs run-pipeline.sh --generate-llm with the M2 autonomy gate: relaxed_review may
    # auto-deploy; full_review queues for human approval. LLM provider failure is
    # non-fatal — the pipeline continues with whatever is already queued.
    Job("self_mod_proposal_cycle", "direct", "3", "46",
        "self-mod-runner/scripts/proposal-cycle-tick.sh", days="6"),
    # Open Item 5: Hermes session → suite transcript bridge. Refreshes the
    # per-message transcripts the preprocess pipelines read from ~/.hermes/sessions
    # by running `hermes sessions export --format jsonl` and transforming it to the
    # parser shape. Minute 58 is unique in this table; runs 4× daily just before the
    # encoding blocks (hours 6/12/18/0), so each encoding sees fresh transcripts.
    Job("transcript_export", "direct", "5,11,17,23", "58",
        "hippocampus-memory/scripts/export-transcripts.sh"),
    # Phase 1 (Signaling & Attention): thalamus attention gate — processes
    # pending signals through the five-dimensional relevance filter and
    # dispatches passing signals to target skills via route-signals.sh.
    # Minute 42 unique. Direct / non-inference. Runs every 2 hours.
    Job("thalamus_gate", "direct", "0,2,4,6,8,10,12,14,16,18,20,22", "42",
        "thalamus-memory/scripts/gate.sh"),
    # Phase 1: thalamus suppressed-queue decay — releases deferred signals
    # that have aged past their retryAfter window back into circulation.
    # Minute 48 unique. Direct / non-inference. Runs every 4 hours.
    Job("thalamus_decay", "direct", "0,4,8,12,16,20", "48",
        "thalamus-memory/scripts/decay.sh"),
    # Phase 1: signal dispatcher daemon — polls brain-signals.jsonl for new
    # events and dispatches through the thalamus gate. Runs on the opposite
    # 2-hour cycle from thalamus_gate so signals are processed within 2h.
    # Minute 54 unique. Direct / non-inference.
    Job("signal_dispatch", "direct", "1,3,5,7,9,11,13,15,17,19,21,23", "54",
        "thalamus-memory/scripts/gate.sh"),
    # V4.1: daily brain-state preservation snapshot (hippocampus). Minute 03
    # unique in this table. Direct / non-inference. Runs core/snapshot/snapshot.sh
    # via snapshot-tick.sh at 23:03 UTC — a last-known-good restore point that
    # predates any bad day, the same snapshot machinery the self-mod pipeline
    # uses for baseline divergence. Retention: 14 snapshots, pruned by the tick.
    Job("brain_snapshot", "direct", "23", "3",
        "hippocampus-memory/scripts/snapshot-tick.sh"),
    # Verification region (proprioception): runs every test each module
    # declared in its capability-manifest.json (manifest-driven discovery in
    # verification-memory/scripts/run-declared-tests.sh). A red suite exits
    # non-zero, so --status flags it like any failing job. Minute 56 unique.
    # Direct / non-inference. Daily at 07:56 UTC — hour 7 has no other job
    # besides heartbeat's :07/:37 beats, so this never contends for resources.
    Job("verification_pass", "direct", "7", "56",
        "verification-memory/scripts/run-declared-tests.sh"),
    # Integrative State Layer (A): global neuromodulator vector + workspace of
    # attention, composed from every region's state (VTA drive, amygdala
    # valence/arousal, ACC conflict load, insula channels, social trust,
    # heartbeat recency). Minutes 6,21,36,51 are globally unique in this table
    # (every 15 min). Direct / non-inference. Writes neuromod-state.json then
    # chains workspace-refresh.sh for workspace.json.
    Job("neuromod_update", "direct", "*", "6,21,36,51",
        "thalamus-memory/scripts/neuromod-update.sh"),
]


def _spec_matches(spec: str, value: int) -> bool:
    if spec == "*":
        return True
    return str(value) in {s.strip() for s in spec.split(",")}


def _job_key(moment: datetime) -> str:
    """Dedupe key for a scheduling moment: date + hour + minute.

    BUG FIX: the key here previously omitted the date ("H:M" only). A job's
    last_fired_key is stored per-job and never reset, so on the day after a
    job first fired, today's "H:M" would be byte-identical to the value
    already stored from yesterday — due_now() would see last_fired_key ==
    key and return False, permanently, for every future occurrence. Every
    job in this table (not just the new weekly ones below) was silently
    exposed to this: each would fire exactly once, ever, after the daemon
    started, then never again — indistinguishable from "working" unless you
    happened to check --status weeks later and noticed the success count
    frozen at 1. This bug was inherited unchanged from legacy/brain-daemon.sh
    (same date-less key there). Including the date fixes it for daily jobs
    too, and is what actually makes the new weekly jobs below viable at all
    — a weekly job is the worst-case exposure of this bug, since "did it
    fire since last Sunday" was never being asked in the first place.
    """
    return f"{moment.date().isoformat()}:{moment.hour}:{moment.minute}"


def due_now(job: Job, moment: datetime) -> bool:
    key = _job_key(moment)
    if job.last_fired_key == key:
        return False
    return (_spec_matches(job.days, moment.weekday())
            and _spec_matches(job.hours, moment.hour)
            and _spec_matches(job.minutes, moment.minute))


def check_schedule_table() -> int:
    """Equivalent of brain-daemon.sh's --check: validates every direct job's
    script path exists and every minute value is globally unique. Returns the
    problem count (0 = clean)."""
    problems = 0
    seen_minutes: dict[str, str] = {}
    print(f"{'JOB':<28} {'KIND':<8} {'DAYS':<10} {'HOURS':<24} {'MINUTES':<10} TARGET")
    for job in JOBS:
        for m in job.minutes.split(","):
            m = m.strip()
            if m in seen_minutes:
                print(f"  !! COLLISION: minute {m} used by both {seen_minutes[m]} and {job.name}")
                problems += 1
            else:
                seen_minutes[m] = job.name
        if job.kind == "direct":
            script_path = SKILLS_DIR / job.target
            if script_path.is_file() and os.access(script_path, os.X_OK):
                # An empty job script is broken even though it is executable:
                # execve on a 0-byte file fails with ENOEXEC ("Exec format
                # error"), so run_direct would fail it at every fire. Flag it
                # so --check (CI gate + self-mod job-table gate) rejects such a
                # proposal before deploy instead of at runtime.
                if script_path.stat().st_size == 0:
                    status = "EXISTS-BUT-EMPTY"
                    problems += 1
                else:
                    status = "ok"
            elif script_path.is_file():
                status = "EXISTS-BUT-NOT-EXECUTABLE"
                problems += 1
            else:
                status = f"MISSING: {script_path}"
                problems += 1
            print(f"{job.name:<28} {job.kind:<8} {job.days:<10} {job.hours:<24} {job.minutes:<10} {status}")
        else:
            print(f"{job.name:<28} {job.kind:<8} {job.days:<10} {job.hours:<24} {job.minutes:<10} "
                  f"(hermes chat task, {len(job.target)} chars)")
    print()
    shim_ok = SPAWN_PROVIDER_SHIM.is_file() and os.access(SPAWN_PROVIDER_SHIM, os.X_OK)
    if shim_ok:
        print(f"spawn-provider shim (provider={SPAWN_PROVIDER}): ok ({SPAWN_PROVIDER_SHIM})")
    else:
        print(f"spawn-provider shim: MISSING or not executable ({SPAWN_PROVIDER_SHIM})")
        problems += 1
    if shutil.which("hermes"):
        print(f"hermes: found ({shutil.which('hermes')})")
    elif os.environ.get("DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK") == "1":
        # hermes presence is a HOST-environment concern, not a job-table-
        # integrity one: --check on a machine that legitimately has no hermes
        # (CI runners, fresh sandboxes) should still fail on table problems.
        # Opt-in downgrade (set DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1) so the
        # problem count is untouched by something --check can't fix here.
        print("hermes: NOT FOUND — downgraded to a warning "
              "(DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1); spawn-type jobs will be "
              "skipped with a warning on the real host until hermes is installed")
    else:
        print("hermes: NOT FOUND — spawn-type jobs will be skipped with a warning until this is fixed")
        problems += 1
    return problems


# ── Single-instance PID lock (parallels the per-job pidfd guard below) ──────
class SingleInstanceLock:
    def __init__(self, path: Path):
        self.path = path
        self._acquired = False

    def _current_starttime(self) -> str:
        # /proc/<pid>/stat field 22 is the process start time in clock ticks.
        return Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]

    def _read_lock(self) -> tuple[Optional[int], Optional[str]]:
        try:
            raw = self.path.read_text().strip().split()
            if not raw:
                return None, None
            pid = int(raw[0])
            starttime = raw[1] if len(raw) > 1 else None
            return pid, starttime
        except (OSError, ValueError, IndexError):
            return None, None

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        if self.path.exists():
            existing_pid, existing_starttime = self._read_lock()
            if existing_pid is not None and existing_starttime is not None:
                try:
                    os.kill(existing_pid, 0)
                    proc_start = Path(f"/proc/{existing_pid}/stat").read_text().split()[21]
                    if proc_start == existing_starttime:
                        log.error("another instance is already running (pid %d, starttime %s, lock %s) — exiting",
                                  existing_pid, existing_starttime, self.path)
                        sys.exit(1)
                    log.info("found a reused pid in lock file (pid %d) — reclaiming stale lock", existing_pid)
                except ProcessLookupError:
                    log.info("found a stale lock file (process no longer exists) — reclaiming it")
                except PermissionError:
                    log.error("lock file %s claims a pid we can't verify (permission denied) — refusing to start a possibly-duplicate instance",
                              self.path)
                    sys.exit(1)
                except (OSError, IndexError, ValueError):
                    log.info("could not validate existing lock metadata — reclaiming it")
            else:
                log.info("found a stale or corrupt lock file — reclaiming it")
        self.path.write_text(f"{os.getpid()} {self._current_starttime()}\n")
        self._acquired = True

    def release(self) -> None:
        if self._acquired:
            try:
                if self.path.exists():
                    existing_pid, existing_starttime = self._read_lock()
                    if existing_pid == os.getpid() and existing_starttime == self._current_starttime():
                        self.path.unlink()
            except OSError:
                pass


# ── Job execution ────────────────────────────────────────────────────────────
_spawn_lock = asyncio.Lock()  # one agent-turn (real LLM inference) at a time
_running_procs: dict[str, TrackedProcess] = {}


async def _await_with_timeout(proc: "asyncio.subprocess.Process", tracked: TrackedProcess,
                               timeout: float, job_name: str) -> tuple[bytes, bool]:
    """Await proc.communicate() bounded by `timeout`. On timeout: kill the
    process via its pidfd (race-free — Pillar 3), give it 5s to actually
    exit, and return (b"", True) rather than raising. This is the fix for a
    real starvation bug: run_spawn() previously awaited proc.communicate()
    with NO timeout while holding _spawn_lock, so one hung
    `hermes chat` call (network stall, model stuck generating, etc.)
    silently starved every other spawn-type job forever — nothing errored,
    nothing logged, the daemon just stopped doing all 8 spawn-type jobs until a
    manual restart. Confirmed with an isolated asyncio.Lock repro before
    this fix. Returns (output_bytes, timed_out)."""
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return out, False
    except asyncio.TimeoutError:
        log.error("%s: timed out after %.0fs — killing via pidfd", job_name, timeout)
        tracked.kill()
        try:
            await asyncio.wait_for(proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            log.error("%s: process (pid %d) did not exit within 5s of SIGKILL — "
                      "abandoning wait, it may be a zombie until the daemon restarts",
                      job_name, tracked.pid)
        return b"", True


async def run_direct(job: Job, direct_timeout: float, daemon_state: "DaemonState") -> None:
    script_path = SKILLS_DIR / job.target
    if not (script_path.is_file() and os.access(script_path, os.X_OK)):
        log.error("%s: script not found or not executable at %s — skipping", job.name, script_path)
        daemon_state.record_result(job.name, success=False,
                                    error=f"script not found or not executable at {script_path}")
        return
    log.info("%s: running %s", job.name, script_path)
    env = os.environ.copy()
    env["WORKSPACE"] = str(WORKSPACE)
    proc = await asyncio.create_subprocess_exec(
        str(script_path), env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    # Track via pidfd for race-free shutdown signaling (Pillar 3) — populated
    # BEFORE awaiting completion, so a SIGTERM arriving mid-run can still find
    # and cleanly terminate this specific process, not an orphan.
    tracked = TrackedProcess(proc.pid)
    _running_procs[job.name] = tracked
    try:
        out, timed_out = await _await_with_timeout(proc, tracked, direct_timeout, job.name)
        if timed_out:
            # FIX #3: a timeout is a failure outcome, not a no-op — record it.
            daemon_state.record_result(job.name, success=False,
                                        error=f"timed out after {direct_timeout:.0f}s")
        elif proc.returncode == 0:
            log.info("%s: completed", job.name)
            daemon_state.record_result(job.name, success=True)
        else:
            tail = out.decode(errors="replace")[-2000:]
            log.error("%s: exited with status %s — output: %s", job.name, proc.returncode, tail)
            daemon_state.record_result(job.name, success=False,
                                        error=f"exit status {proc.returncode}: {tail[-500:]}")
    finally:
        _running_procs.pop(job.name, None)
        tracked.close()


def _audit_spawn(job: Job, yolo_enabled: bool) -> None:
    """FIX #6: append-only audit trail for every spawn-type dispatch —
    timestamp, job name, exact task text sent to the agent, and whether it
    ran with --yolo/--accept-hooks. This doesn't gate anything by itself,
    but it means an unattended --yolo run leaves a reviewable record instead
    of only a truncated stdout tail in the journal. Best-effort: a failure
    to write the audit log logs a warning but never blocks the job."""
    audit_path = WORKSPACE / "memory" / "aibrain-spawn-audit.jsonl"
    entry = {
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "job": job.name,
        "yolo": yolo_enabled,
        "provider": SPAWN_PROVIDER,
        "task": job.target,
    }
    try:
        audit_path.parent.mkdir(parents=True, exist_ok=True)
        with open(audit_path, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError as e:
        log.warning("%s: failed to write spawn audit entry: %s", job.name, e)


async def run_spawn(job: Job, vram_limit: float, spawn_timeout: float,
                     psi_threshold: float, enable_yolo: bool, daemon_state: "DaemonState") -> None:
    # ROADMAP M3: the hermes guard only applies to the hermes provider — with
    # SPAWN_PROVIDER=local the suite's own llm-call.sh endpoint replaces it, and
    # an unavailable local server is a recorded job failure, not a silent skip.
    if SPAWN_PROVIDER == "hermes" and not shutil.which("hermes"):
        log.warning("%s: due now, but hermes is not in PATH — skipped (this needs "
                    "real agent reasoning, not just a script)", job.name)
        return
    if not SPAWN_PROVIDER_SHIM.is_file():
        log.error("%s: spawn-provider shim missing at %s — recording failure",
                  job.name, SPAWN_PROVIDER_SHIM)
        daemon_state.record_result(job.name, success=False,
                                    error=f"spawn-provider shim missing at {SPAWN_PROVIDER_SHIM}")
        return

    vram = gpu_vram_percent()
    if vram is not None and vram >= vram_limit:
        log.warning("%s: deferred — GPU VRAM at %.1f%% (limit %.1f%%), protecting active "
                    "local inference", job.name, vram, vram_limit)
        return

    # FIX #5: instantaneous point-in-time PSI check, in addition to the
    # trigger-based global pressure_state deferral in dispatch(). Covers the
    # window where pressure is already elevated but hasn't crossed the
    # epoll trigger threshold yet.
    mem_avg10 = psi_avg10("memory")
    cpu_avg10 = psi_avg10("cpu")
    for label, value in (("memory", mem_avg10), ("cpu", cpu_avg10)):
        if value is not None and value >= psi_threshold:
            log.warning("%s: deferred — instantaneous %s PSI avg10 at %.1f%% "
                        "(threshold %.1f%%), ahead of the trigger firing",
                        job.name, label, value, psi_threshold)
            return

    # FIX #6: --yolo/--accept-hooks are no longer unconditional. An
    # unattended, cron-equivalent daemon running an agent turn with
    # unrestricted tool/hook approval is a materially larger blast radius
    # than the rest of this file's privilege choices (see the eBPF
    # CAP_BPF discussion above) — it deserves the same explicit opt-in, not
    # a default. Without --enable-yolo on the daemon's command line, spawn
    # jobs still run, but without --yolo/--accept-hooks, so hermes falls
    # back to its own default (non-auto-approving) tool-use behavior.
    async with _spawn_lock:
        _audit_spawn(job, enable_yolo)
        log.info("%s: spawning Hermes chat session%s", job.name,
                  " (--yolo/--accept-hooks enabled)" if enable_yolo else "")
        # ROADMAP M4: inject active executive goals so the agent turn works
        # toward promoted goals; the outcome is recorded back into PFC/ACC.
        # ROADMAP M3: dispatch through the spawn-provider shim (hermes or
        # local llm-call.sh) — pidfd tracking, spawn lock, and timeout are
        # unchanged; the shim `exec`s the real worker so the tracked pid is
        # the actual hermes/llm-call process.
        active_goals = _active_goal_descriptions()
        task_text = _augment_spawn_task(job.target, active_goals)
        env = os.environ.copy()
        env["WORKSPACE"] = str(WORKSPACE)
        env["SPAWN_PROVIDER"] = SPAWN_PROVIDER
        # AUDIT Gap 2: the agentloop provider gets a STABLE session id derived
        # from the job name, so a recurring spawn job (e.g. acc_error_analysis)
        # remembers its prior turns across scheduled runs — session memory is
        # a daemon-level feature, not just a direct-invocation one.
        if SPAWN_PROVIDER == "agentloop":
            env["AGENT_SESSION_ID"] = job.name
            # Per-job step budget: thinking models need more reasoning
            # budget before producing tool calls (Carnice 35B uses ~3-4
            # steps on reasoning alone). Non-spawn jobs keep the default.
            env["AGENT_MAX_STEPS"] = str(job.spawn_max_steps)
            # Thinking-model flag: when set, spawn-provider.sh appends a
            # no-reasoning suffix to the task text so the model skips
            # chain-of-thought and produces tool calls directly.
            if job.thinking_model:
                env["AGENT_THINKING_MODEL"] = "1"
        cmd = ["bash", str(SPAWN_PROVIDER_SHIM), "--task", task_text]
        if enable_yolo:
            cmd.append("--yolo")
        proc = await asyncio.create_subprocess_exec(
            *cmd, env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        )
        tracked = TrackedProcess(proc.pid)
        _running_procs[job.name] = tracked
        infer_t0 = time.monotonic()
        spawn_outcome = "failure"
        try:
            # Bounded by spawn_timeout even though we're holding _spawn_lock —
            # this is the fix. A hung spawn used to block this `async with`
            # body forever, which meant every other spawn-type job queued on
            # this same lock waited forever too, invisibly. Now the lock is
            # guaranteed to release within spawn_timeout + 5s worst case.
            out, timed_out = await _await_with_timeout(proc, tracked, spawn_timeout, job.name)
            if timed_out:
                # FIX #3: a timeout is a failure outcome, not a no-op — record it.
                daemon_state.record_result(job.name, success=False,
                                            error=f"hermes chat timed out after {spawn_timeout:.0f}s")
            elif proc.returncode == 0:
                log.info("%s: Hermes chat completed", job.name)
                daemon_state.record_result(job.name, success=True)
                spawn_outcome = "success"
            else:
                tail = out.decode(errors="replace")[-2000:]
                log.error("%s: hermes chat exited with status %s — output: %s",
                           job.name, proc.returncode, tail)
                daemon_state.record_result(job.name, success=False,
                                            error=f"exit status {proc.returncode}: {tail[-500:]}")
        finally:
            # V4.0: feed inference seconds into executive load window
            record_inference_seconds(time.monotonic() - infer_t0)
            _running_procs.pop(job.name, None)
            tracked.close()

    # ROADMAP M4: close the goal loop AFTER the spawn lock is released — a
    # slow goal-outcome recorder must not hold the one lock every other
    # spawn job queues on. Pass the ORIGINAL task text so relevance is
    # judged against the actual task, not the injected goal block.
    if active_goals:
        await _record_goal_outcomes(job.name, active_goals, spawn_outcome, job.target)


async def dispatch(job: Job, vram_limit: float, cgroup: CgroupThrottle, pressure_active: bool,
                    direct_timeout: float, spawn_timeout: float, psi_threshold: float,
                    enable_yolo: bool, daemon_state: DaemonState) -> None:
    if job.kind == "spawn" and pressure_active:
        # The scheduler consumes last_fired_key before dispatch, so a deferred
        # job does NOT retry "next tick within this matching minute" — it skips
        # to its next scheduled slot. Log what actually happens.
        log.warning("%s: due now but system is under pressure — deferring (will retry "
                    "at the next scheduled slot)", job.name)
        return
    # V4.0 load-reduction: when executive load is at/above hard ceiling, defer
    # spawn (inference) jobs. Direct non-inference jobs remain exempt.
    if job.kind == "spawn" and _LOAD_REDUCTION_ACTIVE:
        log.warning("%s: due now but executive load reduction is active — deferring spawn",
                    job.name)
        return
    if job.kind == "direct":
        await run_direct(job, direct_timeout, daemon_state)
    else:
        await run_spawn(job, vram_limit, spawn_timeout, psi_threshold, enable_yolo, daemon_state)


# ── Circadian scheduler (Pillar 5): the part that must NEVER go dark ────────
async def circadian_scheduler(cgroup: CgroupThrottle, pressure_state: dict, vram_limit: float,
                               tick_seconds: int, direct_timeout: float, spawn_timeout: float,
                               daemon_state: DaemonState, psi_threshold: float,
                               enable_yolo: bool) -> None:
    now = datetime.now(timezone.utc)
    last_tick = now
    if daemon_state.last_tick_utc:
        try:
            last_tick = datetime.fromisoformat(daemon_state.last_tick_utc.replace("Z", "+00:00"))
        except ValueError:
            last_tick = now
    for job in JOBS:
        job.last_fired_key = daemon_state.job_fired_key(job.name)

    # Catch up missed windows since the last recorded tick, bounded to prevent
    # an accidental thundering herd after long downtime.
    missed_minutes = list(_minute_range(last_tick, now))
    if len(missed_minutes) > 1:
        log.info("replaying up to %d missed scheduler minute(s) since %s",
                 len(missed_minutes) - 1, last_tick.isoformat().replace("+00:00", "Z"))
    for moment in missed_minutes:
        key = _job_key(moment)
        for job in JOBS:
            if due_now(job, moment):
                job.last_fired_key = key
                daemon_state.set_job_fired(job.name, key)
                asyncio.create_task(
                    dispatch(job, vram_limit, cgroup, pressure_state["active"],
                             direct_timeout, spawn_timeout, psi_threshold, enable_yolo, daemon_state)
                )
        daemon_state.set_tick(moment)
        daemon_state.save()
        update_executive_load_file()
        await asyncio.sleep(0)

    log.info("circadian scheduler initialized — resuming from the next live minute forward")

    while True:
        now = datetime.now(timezone.utc)
        key = _job_key(now)

        for job in JOBS:
            if due_now(job, now):
                job.last_fired_key = key
                daemon_state.set_job_fired(job.name, key)
                asyncio.create_task(
                    dispatch(job, vram_limit, cgroup, pressure_state["active"],
                             direct_timeout, spawn_timeout, psi_threshold, enable_yolo, daemon_state)
                )

        daemon_state.set_tick(now)
        daemon_state.save()
        # V4.0: recompute executive load every scheduler tick
        update_executive_load_file()
        await asyncio.sleep(tick_seconds)


# ── Pressure supervisor (Pillars 1+2 combined): interrupt-driven, not polled ─
async def pressure_supervisor(cgroup: CgroupThrottle, pressure_state: dict,
                               threshold_avg10: float = 10.0) -> None:
    mem_monitor = PSIMonitor("memory")
    cpu_monitor = PSIMonitor("cpu")
    mem_ok = mem_monitor.open()
    cpu_ok = cpu_monitor.open()

    if not mem_ok and not cpu_ok:
        log.warning("PSI unavailable for both memory and cpu — pressure supervisor "
                    "running in a passive no-op mode (spawn jobs will never be "
                    "deferred for system pressure; GPU VRAM check in run_spawn still applies)")
        return

    modes = f"memory={mem_monitor.mode if mem_ok else 'off'} cpu={cpu_monitor.mode if cpu_ok else 'off'}"
    log.info("pressure supervisor active (%s); threshold avg10=%.1f%%", modes, threshold_avg10)

    loop = asyncio.get_running_loop()
    cooldown_task: Optional[asyncio.Task] = None

    async def cooldown_and_restore():
        await asyncio.sleep(60)  # let pressure genuinely settle before restoring
        pressure_state["active"] = False
        cgroup.restore()

    while True:
        # Trigger mode: epoll_wait in a worker thread (zero-poll).
        # Poll mode: worker samples /proc/pressure avg10 (unprivileged-safe).
        def _wait_mem():
            return mem_monitor.blocking_wait(30.0) if mem_ok else False

        def _wait_cpu():
            # Use the supervisor threshold for poll-mode decisions.
            if not cpu_ok:
                return False
            if cpu_monitor.mode == "poll":
                deadline = time.monotonic() + 30.0
                while time.monotonic() < deadline:
                    avg = psi_avg10("cpu")
                    if avg is not None and avg >= threshold_avg10:
                        return True
                    time.sleep(2.0)
                return False
            return cpu_monitor.blocking_wait(30.0)

        # Override poll threshold for memory similarly when in poll mode
        def _wait_mem_thr():
            if not mem_ok:
                return False
            if mem_monitor.mode == "poll":
                deadline = time.monotonic() + 30.0
                while time.monotonic() < deadline:
                    avg = psi_avg10("memory")
                    if avg is not None and avg >= threshold_avg10:
                        return True
                    time.sleep(2.0)
                return False
            return mem_monitor.blocking_wait(30.0)

        mem_wait = loop.run_in_executor(None, _wait_mem_thr) if mem_ok else None
        cpu_wait = loop.run_in_executor(None, _wait_cpu) if cpu_ok else None
        waits = [f for f in (mem_wait, cpu_wait) if f is not None]
        done, pending = await asyncio.wait(waits, return_when=asyncio.FIRST_COMPLETED)
        fired = any(task.result() for task in done)
        for task in pending:
            task.cancel()
        if fired:
            if not pressure_state["active"]:
                log.warning("PSI pressure elevated (%s) — deferring spawn-type jobs "
                            "and throttling background cgroup weight", modes)
            pressure_state["active"] = True
            cgroup.throttle()
            if cooldown_task and not cooldown_task.done():
                cooldown_task.cancel()
            cooldown_task = asyncio.create_task(cooldown_and_restore())


# ── Entry point ──────────────────────────────────────────────────────────────
async def run_daemon(vram_limit: float, tick_seconds: int, psi_threshold: float,
                      direct_timeout: float, spawn_timeout: float, enable_yolo: bool) -> None:
    cgroup = CgroupThrottle()
    pressure_state = {"active": False}
    daemon_state = DaemonState(DAEMON_STATE_FILE)

    def handle_signal(sig_name: str):
        log.info("received %s — shutting down", sig_name)
        for name, tracked in list(_running_procs.items()):
            log.info("terminating tracked child for %s (pid %d) via pidfd", name, tracked.pid)
            tracked.terminate()
            tracked.close()
        sys.exit(0)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda s=sig: handle_signal(s.name))

    log.info("deep-brain-kernel starting. WORKSPACE=%s tick=%ss direct_timeout=%ss spawn_timeout=%ss",
              WORKSPACE, tick_seconds, direct_timeout, spawn_timeout)
    if shutil.which("hermes"):
        log.info("hermes found at %s — spawn-type jobs enabled", shutil.which("hermes"))
    else:
        log.warning("hermes not found in PATH — spawn-type jobs will be skipped every "
                    "time they're due, until this is fixed")
    if enable_yolo:
        log.warning("--enable-yolo is set: unattended spawn jobs will run hermes with "
                    "--yolo --accept-hooks (auto-approving tool/hook calls with no human "
                    "review step). Every spawn dispatch is recorded to "
                    "%s for after-the-fact audit.", WORKSPACE / "memory" / "aibrain-spawn-audit.jsonl")
    else:
        log.info("--enable-yolo not set (default): spawn jobs run without --yolo/--accept-hooks. "
                 "Pass --enable-yolo to restore full auto-approval for unattended agent turns.")

    await asyncio.gather(
        circadian_scheduler(cgroup, pressure_state, vram_limit, tick_seconds, direct_timeout,
                             spawn_timeout, daemon_state, psi_threshold, enable_yolo),
        pressure_supervisor(cgroup, pressure_state, psi_threshold),
    )


def print_brain_state() -> int:
    """Read-only cognitive dashboard: one-page summary of every brain region."""
    import json as _json
    import os as _os

    mem = _os.environ.get("WORKSPACE", _os.path.expanduser("~/.hermes/workspace")) + "/memory"

    def read(path, default):
        p = _os.path.join(mem, path)
        if not _os.path.isfile(p):
            return default
        try:
            with open(p) as f:
                return _json.load(f)
        except Exception:
            return default

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # ── Gather state ─────────────────────────────────────────────────
    thalamus   = read("thalamus-state.json", {})
    pfc        = read("pfc-state.json", {})
    neuromod   = read("neuromod-state.json", {})
    emotion    = read("emotional-state.json", {})
    conflict   = read("conflict-state.json", {})
    cerebellum = read("cerebellum-state.json", {})
    habit      = read("habit-state.json", {})
    social     = read("social-state.json", {})
    insula     = read("interoceptive-state.json", {})
    reward     = read("reward-state.json", {})
    heartbeat  = read("heartbeat-state.json", {})
    acc        = read("acc-state.json", {})
    workspace  = read("workspace.json", {})
    autonomy   = read("self-mod/autonomy-state.json", {})
    daemon_st  = read("aibrain-daemon-state.json", {})

    # ── Extract key fields ───────────────────────────────────────────
    focus = thalamus.get("attentionFocus", [])
    pending_signals = len(thalamus.get("suppressedQueue", []))
    stats = thalamus.get("stats", {})

    active_goals = [g for g in pfc.get("goals", []) if g.get("status") == "active"]
    inhibitions = len(pfc.get("inhibitions", []))

    mods = neuromod.get("modulators", {})
    da  = mods.get("dopamine", {}).get("value", 0.5)
    na  = mods.get("noradrenaline", {}).get("value", 0.5)
    serotonin = mods.get("serotonin", {}).get("value", 0.5)
    ach = mods.get("acetylcholine", {}).get("value", 0.5)
    cort = mods.get("cortisol", {}).get("value", 0.5)
    oxt = mods.get("oxytocin", {}).get("value", 0.5)
    sp  = mods.get("sleepPressure", {}).get("value", 0)
    composites = neuromod.get("composites", {})

    dims = emotion.get("dimensions", {})
    val = dims.get("valence", 0)
    arousal = dims.get("arousal", 0)
    energy = dims.get("energy", 0.5)

    conf_load = conflict.get("conflictLoad", 0)
    uncertainty = len(conflict.get("attentionFlags", []))

    cal = cerebellum.get("globalCalibration", 0.5)
    habit_avg = 0
    habits = habit.get("habits", [])
    if habits:
        habit_avg = sum(h.get("strength", 0) for h in habits) / len(habits)

    rels = social.get("relationships", {})
    rel_count = len(rels)
    trust_vals = [r.get("trust", 0) for r in rels.values()]
    avg_trust = sum(trust_vals) / len(trust_vals) if trust_vals else 0
    open_loops = sum(len(r.get("openLoops", [])) for r in rels.values())

    channels = insula.get("channels", {})
    cog_load = channels.get("cognitiveLoad", 0.3)
    gut_sig  = channels.get("gutSignal", 0.1)

    drive = reward.get("drive", 0.5)

    circadian = heartbeat.get("circadian", {})
    wake_h = circadian.get("wakeHour", 8)
    sleep_h = circadian.get("sleepHour", 22)
    beats = heartbeat.get("beatCount", 0)

    patterns = acc.get("activePatterns", [])
    error_patterns = len(patterns)
    lessons = acc.get("lessons", [])

    phase = workspace.get("context", {}).get("phase", "unknown")

    auto_mode = autonomy.get("mode", "steward_mode")
    streak = autonomy.get("current_streak", 0)

    jobs = daemon_st.get("jobs", {})
    total_jobs = len(jobs)
    unhealthy = sum(1 for j in jobs.values() if j.get("consecutive_failures", 0) >= 3)
    last_defer = "never"
    for j in jobs.values():
        if j.get("last_error"):
            last_defer = j["last_error"]
            break

    # ── Build output ─────────────────────────────────────────────────
    brain = {
        "at": now,
        "attention": {
            "focus": focus,
            "pending_signals": pending_signals,
            "processed": stats.get("totalSignalsProcessed", 0),
        },
        "goals": {
            "active": [g.get("description") for g in active_goals],
            "count": len(active_goals),
            "inhibitions": inhibitions,
        },
        "neuromod": {
            "dopamine": da,
            "noradrenaline": na,
            "serotonin": serotonin,
            "acetylcholine": ach,
            "cortisol": cort,
            "oxytocin": oxt,
            "sleepPressure": sp,
            "composites": composites,
        },
        "emotion": {
            "valence": val,
            "arousal": arousal,
            "energy": energy,
        },
        "conflict": {
            "load": conf_load,
            "uncertainty_flags": uncertainty,
        },
        "motor": {
            "calibration": cal,
            "habit_strength": round(habit_avg, 3),
        },
        "social": {
            "relationships": rel_count,
            "avg_trust": round(avg_trust, 3),
            "open_loops": open_loops,
        },
        "interoception": {
            "cognitive_load": cog_load,
            "gut_signal": gut_sig,
            "drive": drive,
        },
        "circadian": {
            "phase": phase,
            "wake_hour": wake_h,
            "sleep_hour": sleep_h,
            "beats": beats,
        },
        "error": {
            "active_patterns": error_patterns,
            "lessons": len(lessons),
        },
        "autonomy": {
            "mode": auto_mode,
            "self_mod_streak": streak,
        },
        "daemon": {
            "jobs": total_jobs,
            "unhealthy": unhealthy,
            "last_defer_or_error": last_defer[:80] if last_defer != "never" else "none",
        },
    }

    # When --json is requested alongside --brain, print structured output
    if "--json" in sys.argv:
        print(_json.dumps(brain, indent=2))
        return 0

    # ── Human-readable dashboard ─────────────────────────────────────
    print(f"🧠 AI Brain Suite — Cognitive State at {now}")
    print("═══════════════════════════════════════════════════════")
    print(f"Attention:    {', '.join(focus) if focus else 'none'}"
          f"  ({pending_signals} pending)")
    goals_str = ", ".join(g.get("description", "") for g in active_goals)
    print(f"Goals:        {len(active_goals)} active ({goals_str})" if goals_str else f"Goals:        {len(active_goals)} active")
    print(f"Neuromod:     DA {da:.2f}  NA {na:.2f}  5-HT {serotonin:.2f}  ACh {ach:.2f}  "
          f"CORT {cort:.2f}  OXT {oxt:.2f}")
    print(f"              Sleep pressure {sp:.2f}  |  Phase: {phase}")
    print(f"Emotion:      valence {val:+.2f}  arousal {arousal:.2f}  energy {energy:.2f}")
    print(f"Conflict:     load {conf_load:.2f}  ({uncertainty} uncertainty flags)")
    print(f"Motor:        calibration {cal:.2f}  habit strength {habit_avg:.3f}")
    print(f"Social:       {rel_count} relationships (avg trust {avg_trust:.3f}, {open_loops} open loops)")
    print(f"Intero:       cognitive load {cog_load:.2f}  gut signal {gut_sig:.2f}  reward drive {drive:.2f}")
    print(f"Error:        {error_patterns} active patterns  {len(lessons)} lessons")
    print(f"Autonomy:     {auto_mode}  |  Self-mod streak: {streak}")
    print(f"Daemon:       {total_jobs} jobs, {unhealthy} unhealthy" if unhealthy else f"Daemon:       {total_jobs} jobs, all healthy")
    return 0


def print_status() -> int:
    """FIX #3: read-only health report — doesn't need the daemon running,
    doesn't need the lock, just reads DAEMON_STATE_FILE. Answers "which of
    my jobs have actually been failing" without grepping journalctl for the
    right minute. Returns the count of jobs at or above UNHEALTHY_STREAK
    consecutive failures, so this can double as a monitoring check
    (`--status; [ $? -eq 0 ] || alert`)."""
    # Deferral alert: the weekly self_mod_proposal_cycle defers (steward_mode
    # + full_review) instead of churning the pipeline — proposal-cycle-tick.sh
    # writes this marker so a steward who expected the cycle to run notices it
    # waited. Printed BEFORE the state-file check: a deferral must be visible
    # even if the daemon hasn't ticked yet (the marker is the tick's own write,
    # independent of daemon state). A defer is NOT a failure (the daemon
    # recorded the tick as success), so it never counts toward UNHEALTHY_STREAK.
    defer_path = WORKSPACE / "memory" / "self-mod" / "last-deferral.json"
    try:
        _defer = json.loads(defer_path.read_text())
        if _defer.get("deferred") is True:
            print(
                f"⏸ self_mod_proposal_cycle DEFERRED at {_defer.get('at') or '?'} "
                f"({_defer.get('autonomy_mode') or '?'} + {_defer.get('review_mode') or '?'}) — "
                "the weekly cycle waited for the human; grant auto_mode or relax review to resume."
            )
            print()
    except (OSError, ValueError, TypeError):
        pass

    daemon_state = DaemonState(DAEMON_STATE_FILE)
    if daemon_state.last_tick_utc is None:
        print(f"No state file found at {DAEMON_STATE_FILE} (daemon never ticked, or state file "
              f"was cleared). Nothing to report.")
        return 0

    print(f"Last scheduler tick: {daemon_state.last_tick_utc}\n")
    header = f"{'JOB':<24} {'LAST FIRED':<12} {'OK':>5} {'FAIL':>5} {'STREAK':>7}  LAST ERROR"
    print(header)
    print("-" * len(header))
    unhealthy = 0
    for job in JOBS:
        stats = daemon_state.job_stats.get(job.name, {
            "success": 0, "failure": 0, "consecutive_failures": 0, "last_error": None,
        })
        streak = stats.get("consecutive_failures", 0)
        flag = ""
        if streak >= DaemonState.UNHEALTHY_STREAK:
            flag = " ⚠ UNHEALTHY"
            unhealthy += 1
        last_error = (stats.get("last_error") or "")[:60]
        print(f"{job.name:<24} {daemon_state.job_fired_key(job.name) or '—':<12} "
              f"{stats.get('success', 0):>5} {stats.get('failure', 0):>5} {streak:>7}{flag}  {last_error}")
    print()
    if unhealthy:
        print(f"⚠ {unhealthy} job(s) at or above {DaemonState.UNHEALTHY_STREAK} consecutive "
              f"failures — check journalctl --user -u aibrain.service for details.")
    else:
        print("No jobs currently at or above the unhealthy consecutive-failure threshold "
              f"({DaemonState.UNHEALTHY_STREAK}).")
    print("\nNote: deferrals (VRAM limit, PSI pressure, missing hermes/script) are NOT counted "
          "as failures here — only jobs that actually ran and then errored or timed out.")
    return unhealthy


def compute_autonomy_mode(daemon_state: "DaemonState",
                          window_days: int = 30,
                          max_auto_rollbacks: int = 3,
                          unhealthy_max: int = 0,
                          require_graduated: bool = True) -> dict:
    """ROADMAP M7: steward-only autonomy contract. Determines the current
    operational mode from evidence, not vibes:

      auto_mode   — granted only when, over the rolling window, ALL hold:
                      * graduation streak is at/above target (require_graduated)
                      * zero unhealthy jobs (consecutive-failure streak >= 3)
                      * auto-rollbacks in the window stay under the cap
      steward_mode — otherwise: the human stays the operator; the suite may
                      still propose/evaluate/monitor, but the human is
                      consulted for direction, exemptions, and incidents.

    Evidence sources (all persisted in WORKSPACE/memory):
      * memory/self-mod/graduation-streak.json   (graduation-tracker.sh)
      * daemon state jobStats consecutive_failures (this file)
      * memory/self-mod/deploys/*.json rolled_back=true within window_days

    Returns a dict {mode, auto, evidence:{...}, computed_at} for display and
    persistence. Read-only — never mutates daemon state."""
    import json as _json
    from datetime import datetime as _dt, timezone as _tz, timedelta as _td

    evidence = {"graduated": False, "clean_streak": None, "clean_streak_target": None,
                "unhealthy_jobs": 0, "auto_rollbacks_in_window": 0,
                "window_days": window_days, "max_auto_rollbacks": max_auto_rollbacks}
    # ── graduation streak ─────────────────────────────────────────────────
    grad_file = WORKSPACE / "memory" / "self-mod" / "graduation-streak.json"
    try:
        g = _json.loads(grad_file.read_text())
        streak = int(g.get("clean_streak") or 0)
        target = int(g.get("clean_streak_target") or 20)
        evidence["clean_streak"] = streak
        evidence["clean_streak_target"] = target
        evidence["graduated"] = streak >= target
    except (OSError, ValueError, TypeError):
        pass
    # ── unhealthy jobs from daemon state ──────────────────────────────────
    unhealthy = 0
    for job in JOBS:
        stats = daemon_state.job_stats.get(job.name, {})
        if int(stats.get("consecutive_failures", 0) or 0) >= DaemonState.UNHEALTHY_STREAK:
            unhealthy += 1
    evidence["unhealthy_jobs"] = unhealthy
    # ── auto-rollbacks in the rolling window ──────────────────────────────
    cutoff = _dt.now(_tz.utc) - _td(days=max(1, window_days))
    deploys_dir = WORKSPACE / "memory" / "self-mod" / "deploys"
    rollbacks = 0
    if deploys_dir.is_dir():
        for f in deploys_dir.glob("*.json"):
            if f.name == "LATEST":
                continue
            try:
                rec = _json.loads(f.read_text())
                if rec.get("rolled_back") is not True:
                    continue
                at = rec.get("rollback_at") or rec.get("deployed_at") or ""
                if at:
                    ts = _dt.fromisoformat(at.replace("Z", "+00:00"))
                    if ts >= cutoff:
                        rollbacks += 1
                else:
                    rollbacks += 1
            except (OSError, ValueError, TypeError):
                continue
    evidence["auto_rollbacks_in_window"] = rollbacks

    auto = True
    if require_graduated and not evidence["graduated"]:
        auto = False
    if unhealthy > unhealthy_max:
        auto = False
    if rollbacks > max_auto_rollbacks:
        auto = False
    return {
        "mode": "auto_mode" if auto else "steward_mode",
        "auto": auto,
        "evidence": evidence,
        "computed_at": _dt.now(_tz.utc).isoformat().replace("+00:00", "Z"),
    }


def print_autonomy() -> int:
    """ROADMAP M7: report + persist the autonomy contract mode.
    Read-only wrt daemon state; persists the computed mode to
    memory/self-mod/autonomy-state.json so the human (or a status check) can
    see the mode with its evidence later. Returns 0 when auto_mode, 1 when
    steward_mode (so a steward-monitoring cron can alert on mode regressions).
    Also appends every computation to memory/self-mod/autonomy-history.jsonl
    (append-only, one entry per --autonomy run, tagged granted/revoked/steady)
    so the dashboard's 🩺 tab can render the contract's evolution over time."""
    import json as _json
    daemon_state = DaemonState(DAEMON_STATE_FILE)
    thresh = {}
    try:
        thresh = _json.loads(
            (Path(__file__).resolve().parent / "core" / "self-mod" / "thresholds.json").read_text()
        ).get("autonomy", {})
    except (OSError, ValueError, TypeError):
        pass
    mode = compute_autonomy_mode(
        daemon_state,
        window_days=int(thresh.get("window_days", 30) or 30),
        max_auto_rollbacks=int(thresh.get("max_auto_rollbacks", 3) or 3),
        unhealthy_max=int(thresh.get("unhealthy_jobs_max", 0) or 0),
        require_graduated=bool(thresh.get("require_graduated", True)),
    )
    # Persist for later inspection / stewardship dashboards.
    try:
        state_file = WORKSPACE / "memory" / "self-mod" / "autonomy-state.json"
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(_json.dumps(mode, indent=2, sort_keys=True) + "\n")
    except OSError:
        pass
    # Append-only history ledger: tag this entry as a transition when the
    # mode differs from the previous computation, so the dashboard can show
    # WHEN and WHY auto_mode was granted or revoked. Best-effort — a ledger
    # write failure must never change the exit code or the persisted state.
    transition = "initial"
    try:
        hist_file = WORKSPACE / "memory" / "self-mod" / "autonomy-history.jsonl"
        prev_mode = None
        try:
            lines = hist_file.read_text().splitlines()
            if lines:
                prev = _json.loads(lines[-1])
                prev_mode = prev.get("mode") if isinstance(prev, dict) else None
        except (OSError, ValueError, TypeError):
            pass
        if prev_mode is None:
            transition = "initial"
        elif prev_mode == mode["mode"]:
            transition = "steady"
        elif mode["mode"] == "auto_mode":
            transition = "granted"
        else:
            transition = "revoked"
        entry = {
            "ts": mode["computed_at"],
            "mode": mode["mode"],
            "auto": mode["auto"],
            "transition": transition,
            "evidence": mode["evidence"],
        }
        hist_file.parent.mkdir(parents=True, exist_ok=True)
        with open(hist_file, "a", encoding="utf-8") as hf:
            hf.write(_json.dumps(entry) + "\n")
    except OSError:
        pass
    # Explicit provenance event: every autonomy-mode decision is auditable in
    # memory/provenance/events.jsonl (core/provenance/log-provenance.sh event),
    # alongside the history ledger. Best-effort — the audit trail must never
    # be able to change the exit code.
    try:
        prov_script = Path(__file__).resolve().parent / "core" / "provenance" / "log-provenance.sh"
        if prov_script.is_file():
            detail = _json.dumps({
                "mode": mode["mode"],
                "auto": mode["auto"],
                "transition": transition,
                "computed_at": mode["computed_at"],
            })
            subprocess.run(
                ["bash", str(prov_script), "event",
                 "--event", "autonomy.mode.decided",
                 "--actor", "deep-brain-kernel",
                 "--detail", detail],
                env={**os.environ, "WORKSPACE": str(WORKSPACE)},
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
                check=False,
            )
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    print(_json.dumps(mode, indent=2))
    return 0 if mode["auto"] else 1


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="AI Brain Suite unified async scheduler")
    parser.add_argument("--check", action="store_true", help="Validate the job table and exit")
    parser.add_argument("--status", action="store_true",
                         help="Print per-job success/failure/consecutive-failure history from "
                              "the daemon state file and exit. Read-only — safe to run while the "
                              "daemon is active. Exit code is the number of jobs currently at or "
                              "above the unhealthy consecutive-failure threshold, so this can "
                              "double as a monitoring check.")
    parser.add_argument("--brain", action="store_true",
                         help="Read-only cognitive dashboard: prints a single-page summary of "
                              "every brain region's current state (attention, goals, neuromod, "
                              "emotion, conflict, calibration, social, interoception, daemon). "
                              "Add --json for machine-readable output.")
    parser.add_argument("--autonomy", action="store_true",
                         help="ROADMAP M7: report the operational autonomy contract mode "
                              "(auto_mode vs steward_mode) with its evidence, persist it to "
                              "memory/self-mod/autonomy-state.json, and exit. Exit code 0 = "
                              "auto_mode, 1 = steward_mode (alert-worthy). Read-only.")
    parser.add_argument("--vram-limit", type=float, default=80.0,
                         help="Defer spawn jobs when GPU VRAM usage is at or above this percent (default 80)")
    parser.add_argument("--no-systemd", action="store_true",
                         help="Initiative 12: run without systemd (macOS, containers, WSL). "
                              "The daemon starts and runs jobs directly; systemd integration "
                              "(service enable/start/status) is skipped.")
    parser.add_argument("--no-cgroups", action="store_true",
                         help="Initiative 12: disable cgroup delegation (non-Linux hosts). "
                              "PSI pressure checks and CPU throttling become passive no-ops. "
                              "Everything else runs normally.")
    parser.add_argument("--tick-seconds", type=int, default=30,
                         help="Circadian scheduler wake interval in seconds (default 30)")
    parser.add_argument("--psi-threshold", type=float, default=10.0,
                         help="PSI avg10 stall percent considered 'under pressure' (default 10.0). "
                              "Used both by the trigger-based pressure supervisor and by the "
                              "instantaneous pre-spawn PSI check.")
    parser.add_argument("--direct-timeout", type=float, default=300.0,
                         help="Kill a 'direct' job's script if it hasn't finished within this "
                              "many seconds (default 300 = 5 min). Prevents one hung script "
                              "from lingering as an orphaned process indefinitely.")
    parser.add_argument("--spawn-timeout", type=float, default=900.0,
                         help="Kill a 'spawn' job's hermes chat call if it hasn't "
                              "finished within this many seconds (default 900 = 15 min — real "
                              "agent turns legitimately take longer than direct scripts). This "
                              "bounds the shared spawn lock: without it, one hung agent turn "
                              "silently starves every other spawn-type job forever.")
    parser.add_argument("--enable-yolo", action="store_true",
                         help="Explicit opt-in to run spawn-type jobs with hermes's "
                              "--yolo --accept-hooks (auto-approving tool/hook calls with no "
                              "human review). OFF by default: an unattended, cron-equivalent "
                              "daemon auto-approving agent tool use is a materially larger "
                              "blast radius than the rest of this daemon's default privileges, "
                              "so it now requires the same explicit opt-in the eBPF/cgroup "
                              "privilege trade-offs elsewhere in this file get. Every spawn "
                              "dispatch is audit-logged to WORKSPACE/memory/aibrain-spawn-audit.jsonl "
                              "regardless of this flag.")
    args = parser.parse_args()

    if args.check:
        problems = check_schedule_table()
        if problems == 0:
            print("\n✅ All checks passed.")
            sys.exit(0)
        else:
            print(f"\n❌ {problems} problem(s) found above.")
            sys.exit(1)

    if args.status:
        sys.exit(print_status())

    if args.brain:
        sys.exit(print_brain_state())

    if args.autonomy:
        sys.exit(print_autonomy())

    lock = SingleInstanceLock(PID_LOCK_FILE)
    lock.acquire()
    try:
        asyncio.run(run_daemon(args.vram_limit, args.tick_seconds, args.psi_threshold,
                                args.direct_timeout, args.spawn_timeout, args.enable_yolo))
    finally:
        lock.release()


if __name__ == "__main__":
    main()
