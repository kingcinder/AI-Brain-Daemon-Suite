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
JAMFILE = os.path.join(MEM, "immune-jam.json")

# The jam (Dither-ordered 2026-11-27): cells are counted PER ORGAN, and any
# organ at JAM_THRESHOLD or more accumulated cells jams the whole system.
# Every patrol aspect belongs to exactly one organ. The heart (heartbeat
# organ) carries the system's core aspects — daemon, keeper, pulse, queue,
# spinal cord — and is counted like every other organ (Dither, 2026-11-24).
JAM_THRESHOLD = 3
ASPECT_ORGAN = {
    "daemon process": "heartbeat",
    "keeper process": "heartbeat",
    "pulse log": "heartbeat",
    "spawn queue unacked": "heartbeat",
    "spinal cord (openclaw shim)": "heartbeat",
    "amygdala state": "amygdala",
    "named emotions": "amygdala",
    "backlog pending-emotions.json": "amygdala",
    "insula state": "insula",
    "backlog pending-memories.json": "hippocampus",
    "heart (heartbeat organ state)": "heartbeat",
    "organ directories enumerated": "immune-system",
}


def organ_of(aspect):
    if aspect in ASPECT_ORGAN:
        return ASPECT_ORGAN[aspect]
    if aspect.startswith("organ "):
        return aspect[len("organ "):].strip()
    if aspect.startswith("systemd "):
        return "heartbeat"
    return aspect


def organ_cells(stations):
    """stations: {aspect: station-dict} -> {organ: total cells}."""
    counts = {}
    for aspect, s in stations.items():
        counts[organ_of(aspect)] = counts.get(organ_of(aspect), 0) + s.get("cellsAccumulated", 0)
    return counts


def compute_jam(stations, threshold=JAM_THRESHOLD):
    """Return the list of jammed organs: [{organ, cells, aspects}] at or
    over threshold, worst first. Empty list means no jam."""
    counts = organ_cells(stations)
    jammed = []
    for organ, cells in counts.items():
        if cells >= threshold:
            aspects = sorted(a for a in stations if organ_of(a) == organ)
            jammed.append({"organ": organ, "cells": cells, "aspects": aspects})
    return sorted(jammed, key=lambda j: -j["cells"])

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
    data["organCells"] = organ_cells(stations)
    data["lastUpdate"] = now
    json.dump(data, open(STATIONS, "w"), indent=1)
    json.dump({"updated": now, "queue": queue}, open(FIXQUEUE, "w"), indent=1)
    # The jam file: recomputed from the live stations every cycle. It is
    # never edited by hand and no script clears it — it clears when a patrol
    # measures the organ's aspects at bar and the stations stand down.
    jammed = compute_jam(stations)
    prev = {}
    if os.path.exists(JAMFILE):
        try:
            prev = json.load(open(JAMFILE))
        except Exception:
            prev = {}
    jam = {"jammed": bool(jammed), "organs": jammed, "updated": now}
    if jammed:
        jam["since"] = prev.get("since") if prev.get("jammed") else now
    elif prev.get("jammed"):
        jam["clearedAt"] = now
        jam["lastJam"] = {"organs": prev.get("organs", []), "since": prev.get("since")}
    json.dump(jam, open(JAMFILE, "w"), indent=1)
    print("stations=%d cleared=%s fix_queue=%s" % (
        len(stations), cleared or "none",
        [q["aspect"] for q in queue] or "none"))
    if jammed:
        print("JAM: " + "; ".join(
            "%s %d cells (%s)" % (j["organ"], j["cells"], ", ".join(j["aspects"]))
            for j in jammed))
    return 0

if __name__ == "__main__":
    sys.exit(main())
