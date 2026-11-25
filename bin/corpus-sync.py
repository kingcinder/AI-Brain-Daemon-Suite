#!/usr/bin/env python3
"""corpus-sync — Stage 4 corpus wiring for the Juno helm.

Converts Juno's own runtime session transcripts (the agent lineages
under ~/agents/) into the OpenClaw transcript shape the organ encode
pipelines read from ~/.openclaw/agents/main/sessions/.

v2 (Stage 6 enlargement, 2026-11-11): full scope. v1 ingested only the
two conversational lineages; v2 ingests EVERY lineage under ~/agents/
whose session files carry the shapes this converter faithfully handles
(item types "message" {role, text} and "message_parts" {role, parts}).
All other item types (thinking, function_call, function_call_output,
commentary_text, ...) are passed over exactly as in v1 — they advance
the watermark but produce no corpus record. A lineage with no
convertible items (e.g. a header-only session file) contributes zero
records; nothing is ever force-mapped.

Source shape (per line): {"type":"item","created_at":<iso>,"seq":n,
"item":{"type":"message_parts","role":"user"|"assistant",
"parts":[{"type":"text","text":...}]}}
Target shape: {"type":"message","id":...,"timestamp":<iso>,
"message":{"role":...,"content":[{"type":"text","text":...}]}}

Incremental: a state file remembers the last converted seq per source
session file; new records append to the output file. Machine-generated
user turns (worker-task wrappers, scheduled handoffs) are dropped —
the corpus is conversation, not task boilerplate. Filtering semantics
are unchanged from v1.

Per-run detail (per-lineage added counts, skips) is written to
~/.juno-brain/run/corpus-sync-last-run.json.

Usage: corpus-sync.py [--full]   (--full ignores the watermark state)
"""
import glob
import json
import os
import sys
from datetime import datetime

HOME = os.path.expanduser("~")
AGENTS_ROOT = os.path.join(HOME, "agents")
# The two original conversational lineages (main chat across compaction
# boundaries) are processed first, preserving v1 append order; every
# other lineage dir under ~/agents/ follows in sorted order (v2).
PRIMARY_LINEAGES = [
    "agent-7948eb86-dabb-4588-b1a0-28f99aab5b02",
    "agent-ebd7fbab-d7d8-4f72-af84-57a39281b8a4",
]


def source_dirs() -> list[str]:
    dirs = [os.path.join(AGENTS_ROOT, name, "sessions")
            for name in PRIMARY_LINEAGES]
    try:
        rest = sorted(os.listdir(AGENTS_ROOT))
    except OSError:
        rest = []
    for name in rest:
        if name in PRIMARY_LINEAGES:
            continue
        cand = os.path.join(AGENTS_ROOT, name, "sessions")
        if os.path.isdir(cand):
            dirs.append(cand)
    return dirs


OUT_DIR = os.path.join(HOME, ".openclaw", "agents", "main", "sessions")
OUT_FILE = os.path.join(OUT_DIR, "juno-conversation.jsonl")
STATE_FILE = os.path.join(HOME, ".juno-brain", "run", "corpus-sync-state.json")
RUN_REPORT_FILE = os.path.join(HOME, ".juno-brain", "run",
                               "corpus-sync-last-run.json")

MACHINE_PREFIXES = (
    "[WORKER TASK]",
    "[SCHEDULED TASK HANDOFF]",
    "[PROACTIVITY HANDOFF]",
)


def norm_ts(raw: str) -> str | None:
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except Exception:
        return None
    return dt.isoformat(timespec="microseconds")


def convert_session(path: str, last_seq: int) -> tuple[list[dict], int]:
    records = []
    max_seq = last_seq
    session_id = os.path.basename(path).removesuffix(".jsonl")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") != "item":
                continue
            seq = d.get("seq")
            if not isinstance(seq, int) or seq <= last_seq:
                continue
            item = d.get("item") or {}
            if item.get("type") == "message":
                # Main-lineage shape: {"type":"message","role":...,
                # "text": "..."}
                text = str(item.get("text", "")).strip()
                role = item.get("role")
            elif item.get("type") == "message_parts":
                # Worker-lineage shape: text split across parts.
                text = "\n".join(
                    p.get("text", "") for p in item.get("parts", [])
                    if isinstance(p, dict) and p.get("type") == "text"
                ).strip()
                role = item.get("role")
            else:
                if seq > max_seq:
                    max_seq = seq
                continue
            if role not in ("user", "assistant"):
                if seq > max_seq:
                    max_seq = seq
                continue
            if seq > max_seq:
                max_seq = seq
            if not text:
                continue
            if role == "user" and text.startswith(MACHINE_PREFIXES):
                continue
            ts = norm_ts(d.get("created_at", ""))
            if ts is None:
                continue
            records.append({
                "type": "message",
                "id": f"{session_id}-{seq}",
                "timestamp": ts,
                "message": {
                    "role": role,
                    "content": [{"type": "text", "text": text}],
                },
            })
    return records, max_seq


def main() -> int:
    full = "--full" in sys.argv
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    state = {}
    if not full and os.path.exists(STATE_FILE):
        try:
            state = json.load(open(STATE_FILE))
        except Exception:
            state = {}
    total_new = 0
    mode = "w" if full else "a"
    run_report = {"mode": "full" if full else "incremental",
                  "lineages": {}, "skipped_files": []}
    with open(OUT_FILE, mode, encoding="utf-8") as out:
        for src_dir in source_dirs():
            lineage = os.path.basename(os.path.dirname(src_dir))
            lin_added = 0
            lin_files = 0
            for path in sorted(glob.glob(os.path.join(src_dir, "*.jsonl"))):
                lin_files += 1
                last = -1 if full else int(state.get(path, -1))
                try:
                    records, max_seq = convert_session(path, last)
                except OSError as e:
                    # Unreadable file: skip it WITHOUT advancing its
                    # watermark, so a later run can retry it.
                    run_report["skipped_files"].append(
                        {"path": path, "error": str(e)})
                    continue
                for r in records:
                    out.write(json.dumps(r, ensure_ascii=False) + "\n")
                lin_added += len(records)
                state[path] = max_seq
            run_report["lineages"][lineage] = {
                "files": lin_files, "added": lin_added}
            total_new += lin_added
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1)
    run_report["total_new"] = total_new
    run_report["lineages_scanned"] = len(run_report["lineages"])
    run_report["lineages_with_additions"] = sum(
        1 for v in run_report["lineages"].values() if v["added"] > 0)
    try:
        with open(RUN_REPORT_FILE, "w", encoding="utf-8") as f:
            json.dump(run_report, f, indent=1)
    except OSError:
        pass
    size = os.path.getsize(OUT_FILE) if os.path.exists(OUT_FILE) else 0
    print(f"corpus-sync: +{total_new} messages "
          f"({'full' if full else 'incremental'}); "
          f"{run_report['lineages_scanned']} lineages scanned, "
          f"{run_report['lineages_with_additions']} with additions, "
          f"{len(run_report['skipped_files'])} files skipped; "
          f"{OUT_FILE} now {size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
