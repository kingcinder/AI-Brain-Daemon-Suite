#!/usr/bin/env python3
# immune-stations-update.py — the flood, in code. Reads the newest patrol
# block from the patrol log and updates memory/immune-stations.json:
#   - a stationed aspect that still fails: cellsAccumulated += 1
#   - cellsAccumulated >= repairThreshold: repairState = "threshold-reached"
#     and the aspect is placed on the fix queue (memory/immune-fix-queue.json)
#   - a stationed aspect that now passes: station cleared (pass-through)
#   - a failing aspect with no station: new station, cellsAccumulated = 1
# Repairs themselves stay Juno's gated, checklist-bound work — this script
# detects, accumulates, and escalates. It never treats.
# Juno Moneta, 2026-11-24.
import json, os, re, sys
from datetime import datetime

WS = os.path.expanduser("~/.juno-brain/workspace")
MEM = os.path.join(WS, "memory")
LOG = os.path.join(MEM, "immune-patrol.log")
STATIONS = os.path.join(MEM, "immune-stations.json")
FIXQUEUE = os.path.join(MEM, "immune-fix-queue.json")

def latest_block():
    if not os.path.exists(LOG):
        return ""
    text = open(LOG).read()
    blocks = text.split("## Immune patrol")
    return blocks[-1] if len(blocks) > 1 else ""

def failing_aspects(block):
    fails = set()
    for raw in block.splitlines():
        line = raw.strip().lstrip("- ").strip()
        if "— WARNING" in line or line.endswith("WARNING"):
            aspect = line.split(":")[0].strip()
            fails.add(aspect)
        elif line.startswith("systemd ") and ("inactive" in line or "unknown" in line or "failed" in line):
            # Supervision on this VM reports through files/plain processes;
            # a non-active systemd line is recorded but is not a station —
            # the process checks above are the operative signal here.
            pass
    return fails

def main():
    block = latest_block()
    fails = failing_aspects(block)
    data = json.load(open(STATIONS)) if os.path.exists(STATIONS) else {"stations": []}
    stations = {s["aspect"]: s for s in data.get("stations", [])}
    now = datetime.now().astimezone().isoformat(timespec="seconds")
    cleared = []
    for aspect in list(stations):
        if aspect not in fails:
            cleared.append(aspect)
            del stations[aspect]
    for aspect in fails:
        if aspect in stations:
            stations[aspect]["cellsAccumulated"] = stations[aspect].get("cellsAccumulated", 1) + 1
            stations[aspect]["lastReport"] = "FAILING"
        else:
            stations[aspect] = {
                "aspect": aspect, "bar": "patrol pass", "lastReport": "FAILING",
                "since": now, "status": "STATIONED", "cellsAccumulated": 1,
                "repairThreshold": 3, "repairState": "accumulating",
            }
    queue = []
    for aspect, s in stations.items():
        if s["cellsAccumulated"] >= s.get("repairThreshold", 3):
            s["repairState"] = "threshold-reached"
            queue.append({"aspect": aspect, "cellsAccumulated": s["cellsAccumulated"],
                          "since": s.get("since"), "queuedAt": now})
    data["stations"] = sorted(stations.values(), key=lambda s: -s["cellsAccumulated"])
    data["lastUpdate"] = now
    json.dump(data, open(STATIONS, "w"), indent=1)
    json.dump({"updated": now, "queue": queue}, open(FIXQUEUE, "w"), indent=1)
    print("stations=%d cleared=%s fix_queue=%s" % (
        len(stations), cleared or "none",
        [q["aspect"] for q in queue] or "none"))
    return 0

if __name__ == "__main__":
    sys.exit(main())
