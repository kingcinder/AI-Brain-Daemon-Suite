#!/bin/bash
# export-transcripts.sh — Juno session → suite transcript bridge (Open Item 5).
#
# The suite's memory preprocess scripts (hippocampus, amygdala, VTA, basal
# ganglia, ACC-error, social, insula) consume per-message JSONL transcripts:
#
#     {"type":"message","message":{"role":"user","content":"..."},"timestamp":"ISO-8601"}
#
# Juno's own sessions are the source. By default the bridge reads the
# session files the helm corpus already maintains
# (~/.openclaw/agents/main/sessions/*.jsonl — per-message lines) and
# rewrites them into the normalized per-message shape above. If
# JUNO_SESSION_EXPORT is set, it names a command that writes session JSONL
# to a file argument instead (session-level objects with a "messages"
# array are also accepted — the transform handles both shapes); tests use
# that seam with a Juno stub. The preprocess watermark
# (lastProcessedTimestamp) makes re-export idempotent — messages already
# seen are skipped on the next run.
#
# Environment:
#   WORKSPACE          - suite workspace (default ~/.juno-brain/workspace)
#   TRANSCRIPT_DIR     - where the transformed per-message .jsonl is written
#                        (default $WORKSPACE/transcripts)
#   JUNO_SESSION_DIR   - Juno session files to read in default mode
#                        (default ~/.openclaw/agents/main/sessions)
#   JUNO_SESSION_EXPORT - command that writes session JSONL to a file arg
#
# Exit codes: 0 success · 3 Juno session source unavailable · 4 export/read
# failed · 5 transform failed

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-$WORKSPACE/transcripts}"
JUNO_SESSION_DIR="${JUNO_SESSION_DIR:-$HOME/.openclaw/agents/main/sessions}"
JUNO_SESSION_EXPORT="${JUNO_SESSION_EXPORT:-}"
OUTFILE="juno-sessions.jsonl"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --transcript-dir) TRANSCRIPT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$TRANSCRIPT_DIR"

STAGE=""
TMPOUT="$TRANSCRIPT_DIR/$OUTFILE.tmp"
trap 'rm -f "$STAGE" "$TMPOUT"' EXIT

if [ -n "$JUNO_SESSION_EXPORT" ]; then
    STAGE="$(mktemp "$TRANSCRIPT_DIR/.export-stage.XXXXXX.jsonl")"
    echo "export-transcripts: collecting Juno sessions via JUNO_SESSION_EXPORT..."
    # The export command receives the stage file as its last argument.
    if ! $JUNO_SESSION_EXPORT "$STAGE"; then
        echo "export-transcripts: Juno session export failed" >&2
        exit 4
    fi
    if [ ! -s "$STAGE" ]; then
        echo "export-transcripts: Juno session export produced no data" >&2
        exit 4
    fi
    SRC="$STAGE"
else
    if [ ! -d "$JUNO_SESSION_DIR" ]; then
        echo "export-transcripts: Juno session source unavailable: $JUNO_SESSION_DIR not found" >&2
        exit 3
    fi
    shopt -s nullglob
    SESSION_FILES=("$JUNO_SESSION_DIR"/*.jsonl)
    shopt -u nullglob
    if [ "${#SESSION_FILES[@]}" -eq 0 ]; then
        echo "export-transcripts: Juno session source unavailable: no .jsonl in $JUNO_SESSION_DIR" >&2
        exit 3
    fi
    echo "export-transcripts: reading ${#SESSION_FILES[@]} Juno session file(s) from $JUNO_SESSION_DIR..."
    # Default mode streams the session files directly (no staging copy —
    # Juno's live session file can be ~1GB, a copy would double its cost).
    SRC="$JUNO_SESSION_DIR"
fi

echo "export-transcripts: transforming to per-message transcripts in $TRANSCRIPT_DIR..."
# `if !` keeps errexit off inside the condition, so a failed transform exits 5
# here (not with python's raw exit code from `set -e` aborting the script).
# NOTE: `! python3` is true exactly when python FAILS — so a failed run takes
# the `then` branch and exits 5; a successful run falls through.
if ! python3 - "$SRC" "$TRANSCRIPT_DIR/$OUTFILE" << 'PY'
import json
import os
import sys
from datetime import datetime, timezone

src, dst = sys.argv[1], sys.argv[2]

def to_iso(ts):
    if isinstance(ts, (int, float)):
        try:
            return datetime.fromtimestamp(float(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (TypeError, ValueError, OSError):
            return None
    if isinstance(ts, str) and ts.strip():
        text = ts.strip()
        try:
            dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return None

def message_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        return " ".join(parts).strip()
    return ""

def emit(g, role, content, ts_raw, counters):
    if role not in ("user", "assistant"):
        counters["skipped"] += 1
        return
    ts = to_iso(ts_raw)
    if not ts:
        counters["skipped"] += 1
        return
    text = message_text(content)
    if not text.strip():
        counters["skipped"] += 1
        return
    out = {
        "type": "message",
        "message": {"role": role, "content": text},
        "timestamp": ts,
    }
    g.write(json.dumps(out, ensure_ascii=False) + "\n")
    counters["written"] += 1

counters = {"written": 0, "skipped": 0}

def source_lines(path):
    import glob as _glob
    if os.path.isdir(path):
        files = sorted(_glob.glob(os.path.join(path, "*.jsonl")))
    else:
        files = [path]
    for fp in files:
        with open(fp, "r", encoding="utf-8", errors="replace") as fh:
            yield from fh

with open(dst + ".tmp", "w", encoding="utf-8") as g:
    for line in source_lines(src):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record.get("messages"), list):
            # Session-level object: one whole session per line.
            for msg in record.get("messages") or []:
                emit(g, msg.get("role"), msg.get("content"), msg.get("timestamp"), counters)
        elif isinstance(record.get("message"), dict):
            # Per-message object: Juno's own session file shape.
            msg = record["message"]
            emit(g, msg.get("role"), msg.get("content"), record.get("timestamp"), counters)

os.replace(dst + ".tmp", dst)
print(f"export-transcripts: wrote {counters['written']} messages to {dst} ({counters['skipped']} non user/assistant or empty skipped)")
PY
then
    echo "export-transcripts: transform failed" >&2
    exit 5
fi

echo "export-transcripts: done — $TRANSCRIPT_DIR/$OUTFILE ready for the memory preprocess pipelines"
exit 0
