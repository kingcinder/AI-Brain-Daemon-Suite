#!/usr/bin/env python3
"""regulate.py — the hypothalamus organ's regulation pass.

Reads the milieu variables, compares them against the set-points in
memory/hypothalamus-state.json, and for each out-of-bounds variable
issues a corrective drive: a gated envelope (homeostasis.drive) via
core/gate/envelope.py + a ledger entry in
memory/homeostasis-ledger.jsonl (via the conservation writer).

Variables (live mode):
  queue_depth, deadletter_count   — `openclaw health`
  pending_total                    — sum of memory/pending-*.json lists
  vm_disk_free_pct                 — shutil.disk_usage(workspace)
  insula_cognitive_load,
  insula_context_saturation        — memory/interoceptive-state.json

Fixture mode: HYPOTHALAMUS_VARS_JSON points at a JSON file with the
variable values (used by the organ's tests).

Exit 0 on a completed pass (drives issued are data, not failure).
"""
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

WS = os.environ.get("WORKSPACE") or os.path.expanduser("~/.juno-brain/workspace")
MEM = os.path.join(WS, "memory")
NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
PASS_ID = "reg_" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

DEFAULT_SETPOINTS = {
    "queue_depth_max": 10,
    "deadletter_max": 0,
    "pending_total_max": 1000,
    "vm_disk_free_min_pct": 10.0,
    "insula_cognitive_load_max": 0.85,
    "insula_context_saturation_max": 0.85,
}
# variable -> (setpoint key, direction, drive target flow, severity)
RULES = [
    ("queue_depth", "queue_depth_max", "max", "helm-queue", "critical"),
    ("deadletter_count", "deadletter_max", "max", "helm-queue", "critical"),
    ("pending_total", "pending_total_max", "max", "brain-signals", "elevated"),
    ("vm_disk_free_pct", "vm_disk_free_min_pct", "min", "brain-signals", "elevated"),
    ("insula_cognitive_load", "insula_cognitive_load_max", "max", "brain-signals", "elevated"),
    ("insula_context_saturation", "insula_context_saturation_max", "max", "brain-signals", "elevated"),
]


def live_variables():
    v = {}
    try:
        out = subprocess.run([os.path.expanduser("~/.local/bin/openclaw"), "health"],
                             capture_output=True, text=True, timeout=20,
                             env={**os.environ, "BRAIN_WORKSPACE": WS}).stdout
        h = json.loads(out)
        v["queue_depth"] = h.get("queue_depth")
        v["deadletter_count"] = h.get("deadletter_count")
    except Exception:
        pass
    total = 0
    import glob
    for p in glob.glob(os.path.join(MEM, "pending-*.json")):
        try:
            d = json.load(open(p))
            if isinstance(d, dict) and isinstance(d.get("pending"), list):
                total += len(d["pending"])
            elif isinstance(d, list):
                total += len(d)
        except Exception:
            continue
    v["pending_total"] = total
    try:
        u = shutil.disk_usage(WS)
        v["vm_disk_free_pct"] = round(100.0 * u.free / u.total, 1)
    except Exception:
        pass
    try:
        ins = json.load(open(os.path.join(MEM, "interoceptive-state.json")))
        ch = ins.get("channels", {})
        v["insula_cognitive_load"] = ch.get("cognitiveLoad")
        v["insula_context_saturation"] = ch.get("contextSaturation")
    except Exception:
        pass
    return v


def main():
    state_path = os.path.join(MEM, "hypothalamus-state.json")
    state = {}
    if os.path.exists(state_path):
        try:
            state = json.load(open(state_path))
        except Exception:
            state = {}
    setpoints = {**DEFAULT_SETPOINTS, **(state.get("setpoints") or {})}

    fixture = os.environ.get("HYPOTHALAMUS_VARS_JSON")
    if fixture:
        variables = json.load(open(fixture))
    else:
        variables = live_variables()

    drives = []
    for var, sp_key, direction, dest, severity in RULES:
        val = variables.get(var)
        if val is None:
            continue
        bound = setpoints[sp_key]
        out_of_bounds = (val > bound) if direction == "max" else (val < bound)
        if out_of_bounds:
            drives.append({"variable": var, "value": val, "setpoint": bound,
                           "direction": direction, "destination": dest,
                           "severity": severity})

    # Ledger + envelopes for each drive
    writer = os.path.join(WS, "core", "gate", "store_write.py")
    gate = os.path.join(WS, "core", "gate", "envelope.py")
    ledger_path = os.path.join(MEM, "homeostasis-ledger.jsonl")
    for d in drives:
        entry = {"ts": NOW, "pass_id": PASS_ID, "action": "corrective-drive", **d}
        if os.path.exists(writer):
            with open("/tmp/.hypothalamus-entry.json", "w") as f:
                json.dump(entry, f)
            subprocess.run(["python3", writer, "append-jsonl", "--store", ledger_path,
                            "--entry", "/tmp/.hypothalamus-entry.json",
                            "--writer", "hypothalamus-memory/regulate.sh"],
                           env={**os.environ, "WORKSPACE": WS}, capture_output=True)
        else:
            with open(ledger_path, "a") as f:
                f.write(json.dumps(entry) + "\n")
        if os.path.exists(gate):
            env_obj = {
                "signal_id": f"{PASS_ID}_{d['variable']}",
                "origin": "organ", "source_id": "hypothalamus-memory",
                "ts": NOW, "type": "homeostasis.drive",
                "urgency": "critical" if d["severity"] == "critical" else "elevated",
                "destination": d["destination"],
                "provenance": {"parents": [PASS_ID], "evidence": ["memory/homeostasis-ledger.jsonl"]},
                "payload_ref": f"{d['variable']}={d['value']} (setpoint {d['direction']} {d['setpoint']})",
            }
            with open("/tmp/.hypothalamus-env.json", "w") as f:
                json.dump(env_obj, f)
            subprocess.run(["python3", gate, "ingress", "/tmp/.hypothalamus-env.json"],
                           env={**os.environ, "WORKSPACE": WS}, capture_output=True, timeout=40)

    totals = state.get("totals", {})
    totals["passes"] = totals.get("passes", 0) + 1
    totals["drivesIssued"] = totals.get("drivesIssued", 0) + len(drives)
    state.update({
        "version": "1.0",
        "setpoints": setpoints,
        "lastRegulatedAt": NOW,
        "lastUpdated": NOW,
        "variables": variables,
        "activeDrives": drives,
        "totals": totals,
    })
    state.setdefault("lastConsultedAt", None)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

    if drives:
        desc = "; ".join(f"{d['variable']}={d['value']} (bound {d['setpoint']})" for d in drives)
        print(f"🌡️ Hypothalamus regulation {PASS_ID}: {len(drives)} corrective drive(s): {desc}")
    else:
        print(f"🌡️ Hypothalamus regulation {PASS_ID}: all milieu variables within set-points")
    return 0


if __name__ == "__main__":
    sys.exit(main())
