#!/bin/bash
# Unit: deep-brain-kernel.py vulkaninfo memory-budget parsers (M0 fix, 2nd pass).
#
# FIXTURE NOTE: This test uses inline synthetic strings modeled on real
# vulkaninfo output from an RX 5700 XT / RADV navi10 (8 GiB VRAM heap).
# No hardware-specific VP_VULKANINFO_*.json file is committed — the
# fixtures are synthetic analogues of the per-heap text schema, which is
# portable across Vulkan-Tools versions and GPU vendors.  If a
# VP_VULKANINFO_*.json fixture is ever added (e.g. for JSON-path testing),
# it should be anonymized/synthetic rather than a raw hardware capture to
# avoid leaking driver versions or serial numbers.
#
# CORRECTED SEMANTICS (2026-08-08, verified against live vulkaninfo output on
# this RX 5700 XT / RADV navi10 while llama-server holds ~7.16 GiB VRAM):
#   percent_used = (size - budget) / size * 100
# where `budget` is "how much THIS process can still allocate right now"
# (Vulkan accounts for everyone's usage), NOT total heap capacity — and
# `usage` is only vulkaninfo's own trivial allocation, so it is deliberately
# ignored. Only heaps flagged MEMORY_HEAP_DEVICE_LOCAL_BIT count (actual
# VRAM); the 27 GiB host-RAM heap (flags: None) must be excluded.
#
# This host's Vulkan-Tools emits EMPTY stdout for --json (writes a
# VP_VULKANINFO_*.json file with no budget data instead) and its plain-text
# output uses per-heap `size =` / `budget =` lines under `memoryHeaps[N]:`
# blocks, NOT the legacy flat `heapBudget`/`heapUsage` keys — the corrected
# parser matches this schema and drops legacy flat support (legacy text now
# returns None → fail open to amdgpu sysfs, never raises).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT

python3 - "$ROOT/deep-brain-kernel.py" "$WS" << 'PY'
import importlib.util, json, logging, os, sys
logging.disable(logging.CRITICAL)
ws = sys.argv[2]
os.environ["WORKSPACE"] = ws  # bind before exec_module (daemon binds paths at import)
spec = importlib.util.spec_from_file_location("dbk", sys.argv[1])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)

def close(a, b, tol=1e-6):
    return abs(a - b) < tol

# ── Fixture 1: this host's per-heap text schema (RX 5700 XT) ───────────────
# memoryHeaps[0] = 27 GiB host RAM (flags: None → excluded); memoryHeaps[1] =
# 8 GiB DEVICE_LOCAL VRAM with budget = 5 GiB free (i.e. 3 GiB already in
# use by other processes — exactly the corrected budget semantics).
per_heap = """VkPhysicalDeviceMemoryProperties:
=================================
memoryHeaps: count = 2
\tmemoryHeaps[0]:
\t\tsize   = 29360128000 (0x6d6000000) (27.34 GiB)
\t\tbudget = 29142188032 (0x6c9028000) (27.14 GiB)
\t\tusage  = 0 (0x00000000) (0.00 B)
\t\tflags:
\t\t\tNone
\tmemoryHeaps[1]:
\t\tsize   = 8589934592 (0x200000000) (8.00 GiB)
\t\tbudget = 5368709120 (0x140000000) (5.00 GiB)
\t\tusage  = 0 (0x00000000) (0.00 B)
\t\tflags: count = 1
\t\t\tMEMORY_HEAP_DEVICE_LOCAL_BIT
"""

# (8 GiB - 5 GiB free) / 8 GiB → 37.5% used; host-RAM heap excluded.
pct = dbk._parse_vulkaninfo_text(per_heap)
assert pct is not None, "per-heap schema must parse (M0 fix)"
assert close(pct, 37.5), f"expected 37.5%, got {pct}"

# Budget == size (nothing committed by anyone) → 0.0%, not None.
pct0 = dbk._parse_vulkaninfo_text(per_heap.replace("budget = 5368709120 (0x140000000) (5.00 GiB)",
                                                   "budget = 8589934592 (0x200000000) (8.00 GiB)"))
assert pct0 is not None and close(pct0, 0.0), f"expected 0.0%, got {pct0}"

# `usage` is deliberately IGNORED (vulkaninfo's own trivial allocation) —
# changing it must NOT change the result.
pct_usage = dbk._parse_vulkaninfo_text(per_heap.replace("usage  = 0 (0x00000000) (0.00 B)",
                                                        "usage  = 8589934592 (0x200000000) (8.00 GiB)"))
assert close(pct_usage, 37.5), f"usage must be ignored, got {pct_usage}"

# Host-RAM-only heap (no DEVICE_LOCAL flag anywhere) → None (fail open to
# sysfs; never sums host RAM as if it were VRAM).
host_only = per_heap.replace("\t\t\tMEMORY_HEAP_DEVICE_LOCAL_BIT\n", "")
assert dbk._parse_vulkaninfo_text(host_only) is None, \
    "no DEVICE_LOCAL heap → None, never host-RAM washout"

# ── Legacy flat heapBudget/heapUsage schema → None (support dropped) ───────
legacy = "heapBudget = 1000\nheapUsage = 250\nheapBudget = 3000\nheapUsage = 750\n"
assert dbk._parse_vulkaninfo_text(legacy) is None, \
    "legacy flat schema no longer supported — fails open, never raises"

# ── Garbage / empty → None (fail open, never raise) ────────────────────────
assert dbk._parse_vulkaninfo_text("") is None
assert dbk._parse_vulkaninfo_text("no memory data here") is None
assert dbk._parse_vulkaninfo_text("{not json") is None

# ── JSON parser: VP-shaped file (this build) has NO budget data → None ────
vp_json = json.dumps({
    "$schema": "https://schema.khronos.org/vulkan/profiles/1.3.x/json/",
    "capabilities": {"device": {"extensions": {"VK_EXT_memory_budget": 1}}},
    "profiles": {},
})
assert dbk._parse_vulkaninfo_json(vp_json) is None, \
    "VP artifact carries no budget data — must return None, not crash"

# JSON parser still accepts a build that DOES emit heapBudget on stdout
# (unchanged from the prior pass — left as-is per the M0 fix: this host's
# --json emits empty stdout, so this path fails open to plain-text).
real_json = json.dumps({
    "capabilities": {
        "device": {
            "VkPhysicalDeviceMemoryBudgetPropertiesEXT": {
                "heapBudget": [1000, 3000],
                "heapUsage": [250, 750],
            },
            "VkPhysicalDeviceMemoryProperties": {
                "memoryHeaps": [{"flags": "MEMORY_HEAP_DEVICE_LOCAL_BIT"},
                                {"flags": "MEMORY_HEAP_DEVICE_LOCAL_BIT"}],
            },
        }
    }
})
pct = dbk._parse_vulkaninfo_json(real_json)
assert pct is not None and close(pct, 25.0), f"stdout JSON schema: expected 25.0%, got {pct}"

print("PASS: vulkaninfo parsers (per-heap text (size−budget)/size + VP json + stdout json)")
PY
