#!/bin/bash
# export-transcripts.sh — Hermes session → suite transcript bridge (Open Item 5).
#
# The suite's memory preprocess scripts (hippocampus, amygdala, VTA, basal
# ganglia, ACC-error, social, insula) consume per-message JSONL transcripts:
#
#     {"type":"message","message":{"role":"user","content":"..."},"timestamp":"ISO-8601"}
#
# Hermes stores sessions in ~/.hermes/state.db (SQLite), not as those files.
# This bridge runs `hermes sessions export --format jsonl`, which emits one
# whole-session JSON object per line, and rewrites it into the per-message
# shape the parsers already expect. The preprocess watermark
# (lastProcessedTimestamp) makes re-export idempotent — messages already seen
# are skipped on the next run.
#
# Environment:
#   WORKSPACE      - suite workspace (default ~/.hermes/workspace)
#   TRANSCRIPT_DIR - where the transformed per-message .jsonl is written
#                    (default ~/.hermes/sessions — the established default the
#                    preprocess scripts read from)
#   EXPORT_AGE     - age window passed to `hermes sessions export --newer-than`
#                    (default 7d; covers a week of sessions, watermark dedupes)
#   HERMES_BIN     - hermes binary to use (default: hermes on PATH)
#
# Exit codes: 0 success · 3 hermes not found · 4 export failed · 5 transform failed

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-$HOME/.hermes/sessions}"
EXPORT_AGE="${EXPORT_AGE:-7d}"
HERMES_BIN="${HERMES_BIN:-hermes}"
OUTFILE="hermes-sessions.jsonl"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --transcript-dir) TRANSCRIPT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$TRANSCRIPT_DIR"

if ! command -v "$HERMES_BIN" >/dev/null 2>&1; then
    echo "export-transcripts: '$HERMES_BIN' not found on PATH" >&2
    exit 3
fi

STAGE="$(mktemp "$TRANSCRIPT_DIR/.export-stage.XXXXXX.jsonl")"
TMPOUT="$TRANSCRIPT_DIR/$OUTFILE.tmp"
trap 'rm -f "$STAGE" "$TMPOUT"' EXIT

echo "export-transcripts: exporting Hermes sessions (newer than $EXPORT_AGE)..."
if ! "$HERMES_BIN" sessions export --format jsonl --newer-than "$EXPORT_AGE" --yes "$STAGE"; then
    echo "export-transcripts: hermes sessions export failed" >&2
    exit 4
fi

echo "export-transcripts: transforming to per-message transcripts in $TRANSCRIPT_DIR..."
# `if !` keeps errexit off inside the condition, so a failed transform exits 5
# here (not with python's raw exit code from `set -e` aborting the script).
# NOTE: `! python3` is true exactly when python FAILS — so a failed run takes
# the `then` branch and exits 5; a successful run falls through.
if ! python3 - "$STAGE" "$TRANSCRIPT_DIR/$OUTFILE" << 'PY'
import json
import os
import sys
from datetime import datetime, timezone

src, dst = sys.argv[1], sys.argv[2]

def to_iso(ts):
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OSError):
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

written = 0
skipped = 0
with open(src, "r", encoding="utf-8", errors="replace") as f, \
     open(dst + ".tmp", "w", encoding="utf-8") as g:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            session = json.loads(line)
        except json.JSONDecodeError:
            continue
        for msg in session.get("messages") or []:
            role = msg.get("role")
            if role not in ("user", "assistant"):
                skipped += 1
                continue
            ts = to_iso(msg.get("timestamp"))
            if not ts:
                skipped += 1
                continue
            text = message_text(msg.get("content"))
            if not text.strip():
                skipped += 1
                continue
            out = {
                "type": "message",
                "message": {"role": role, "content": text},
                "timestamp": ts,
            }
            g.write(json.dumps(out, ensure_ascii=False) + "\n")
            written += 1

os.replace(dst + ".tmp", dst)
print(f"export-transcripts: wrote {written} messages to {dst} ({skipped} non user/assistant or empty skipped)")
PY
then
    echo "export-transcripts: transform failed" >&2
    exit 5
fi

echo "export-transcripts: done — $TRANSCRIPT_DIR/$OUTFILE ready for the memory preprocess pipelines"
exit 0
