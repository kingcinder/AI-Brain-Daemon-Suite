#!/usr/bin/env python3
"""immune-face-write.py — write the immune system's face, IMMUNE_STATE.md.

The patrol (immune-patrol.sh) is read-only by design and speaks only to the
patrol log; the stations update keeps its own JSON. Nothing ever rendered
their results into IMMUNE_STATE.md, so the face froze at its 2026-11-24 seed
census while the body changed around it. This writer closes that gap: it
renders the latest patrol block, the stations, the fix queue and the last
pulse into the face. It runs at the end of every pulse cycle (helm-pulse.sh)
and on demand from the heartbeat doctor. It changes nothing but the face.
"""
import json
import os
import re
from datetime import datetime
from zoneinfo import ZoneInfo

HOME = os.path.expanduser("~")
WS = os.path.join(HOME, ".juno-brain/workspace")
MEM = os.path.join(WS, "memory")
FACE = os.path.join(WS, "IMMUNE_STATE.md")
PT = ZoneInfo("America/Los_Angeles")


def tail_patrol_block():
    path = os.path.join(MEM, "immune-patrol.log")
    if not os.path.exists(path):
        return [], None
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    blocks = text.split("## Immune patrol — ")
    if len(blocks) < 2:
        return [], None
    last = blocks[-1]
    lines = [ln.rstrip() for ln in last.splitlines()]
    stamp = lines[0].strip() if lines else None
    verdict_lines = [ln for ln in lines[1:] if ln.startswith("- ") or ln.startswith("VERDICT")]
    stations_line = [ln for ln in lines[1:] if ln.startswith("stations=")]
    return (verdict_lines, stamp, stations_line[-1] if stations_line else None)


def load_json(name):
    path = os.path.join(MEM, name)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def last_pulse():
    path = os.path.join(MEM, "heartbeat-pulse.log")
    if not os.path.exists(path):
        return "none recorded"
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [ln.strip() for ln in f if "helm-pulse" in ln]
    return lines[-1] if lines else "none recorded"


def main():
    now = datetime.now(PT).strftime("%Y-%m-%d %H:%M:%S %Z")
    patrol_lines, patrol_stamp, stations_line = tail_patrol_block()
    queue = load_json("immune-fix-queue.json") or {}
    queued = queue.get("queue", [])
    verdict = "unknown — no patrol block found"
    for ln in patrol_lines:
        if ln.startswith("VERDICT"):
            verdict = ln
    warnings = [ln for ln in patrol_lines if "WARNING" in ln]
    out = []
    out.append("# IMMUNE_STATE.md — the immune system's face")
    out.append("")
    out.append(f"Rendered: {now} by immune-face-write.py from the latest patrol"
               f" ({patrol_stamp or 'no patrol yet'}), the stations file and the fix queue.")
    out.append("This face is rewritten every pulse cycle. The original hand-seeded census of"
               " 2026-11-24 is preserved as IMMUNE_STATE.seed-2026-11-24.md.")
    out.append("")
    out.append(f"## Overall: {verdict}")
    out.append("")
    out.append(f"Last pulse: {last_pulse()}")
    out.append("")
    out.append("## Per-aspect verdicts (latest patrol)")
    out.extend(patrol_lines if patrol_lines else ["- no patrol data yet"])
    out.append("")
    out.append("## Stations")
    out.append(f"- {stations_line}" if stations_line else "- no stations line in latest patrol")
    out.append("")
    out.append(f"## Fix queue ({len(queued)} open)")
    if queued:
        for item in queued:
            out.append(f"- {item.get('aspect')}: {item.get('cellsAccumulated')} cells accumulated,"
                       f" open since {item.get('since')}, queued {item.get('queuedAt')}")
    else:
        out.append("- empty — nothing waiting for repair")
    out.append("")
    out.append(f"## Open warnings: {len(warnings)}")
    out.extend(warnings if warnings else ["- none"])
    out.append("")
    with open(FACE, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print(f"immune face written {now}: {verdict}; warnings={len(warnings)} queue={len(queued)}")


if __name__ == "__main__":
    main()
