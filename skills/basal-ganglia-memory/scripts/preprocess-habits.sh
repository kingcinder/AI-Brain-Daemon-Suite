#!/bin/bash
# preprocess-habits.sh — Scan session transcripts for habit signals
#
# Walks every session transcript, extracts user/assistant turns that look
# like behavioral signals (repeated actions, explicit instructions,
# corrections, completed workflows), and writes them to
# memory/habit-signals.jsonl for encode-pipeline.sh to score.
#
# Uses a timestamp watermark (habit-state.json's lastProcessedSignal) to
# only process new turns on incremental runs. On the very first run (no
# watermark yet), honors the signal limit recorded by install.sh
# (memory/.basal-ganglia-signal-limit), unless --full or --limit override it.
#
# Usage:
#   preprocess-habits.sh                # Process turns after the watermark
#   preprocess-habits.sh --full         # Process ALL turns (ignore watermark)
#   preprocess-habits.sh --limit N      # Limit to the last N signals
#
# Environment:
#   WORKSPACE - Hermes workspace directory (default: ~/.hermes/workspace)
#   TRANSCRIPT_DIR - session transcript directory (default: ~/.hermes/sessions;
#                    populate via `hermes sessions export --format jsonl <dir>`)
#   AGENT_ID  - retained for compatibility; transcripts are no longer per-agent by default

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
AGENT_ID="${AGENT_ID:-main}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-$HOME/.hermes/sessions}"
OUTPUT="$WORKSPACE/memory/habit-signals.jsonl"
STATE_FILE="$WORKSPACE/memory/habit-state.json"
LIMIT_FILE="$WORKSPACE/memory/.basal-ganglia-signal-limit"

# Parse arguments
FULL_MODE=false
LIMIT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            FULL_MODE=true
            shift
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Count session files
SESSION_COUNT=$(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SESSION_COUNT" -eq 0 ]; then
    echo "No session transcripts found in $TRANSCRIPT_DIR"
    echo "Hint: populate it with: hermes sessions export --format jsonl \"$TRANSCRIPT_DIR\""
    exit 1
fi

echo "🎯 Basal Ganglia Preprocess"
echo "==========================="
echo "Processing: $SESSION_COUNT session files in $TRANSCRIPT_DIR"
echo "Mode: $([ "$FULL_MODE" = true ] && echo 'FULL (all turns)' || echo 'incremental')"

# Export variables for Python
export TRANSCRIPT_DIR OUTPUT STATE_FILE LIMIT_FILE FULL_MODE LIMIT

python3 << 'PYTHON_SCRIPT'
import os
import re
import json
from datetime import datetime
from glob import glob

transcript_dir = os.environ.get('TRANSCRIPT_DIR', '')
output_file = os.environ.get('OUTPUT', '')
state_file = os.environ.get('STATE_FILE', '')
limit_file = os.environ.get('LIMIT_FILE', '')
full_mode = os.environ.get('FULL_MODE', 'false') == 'true'
limit_str = os.environ.get('LIMIT', '')
limit = int(limit_str) if limit_str and limit_str.isdigit() else None

# Get watermark timestamp from habit-state.json's lastProcessedSignal.
# By convention, a basal-ganglia signal's "id" IS its ISO-8601 timestamp,
# so the watermark can be parsed directly as a datetime for comparison.
watermark_ts = None
had_watermark = False
if not full_mode and os.path.exists(state_file):
    try:
        with open(state_file) as f:
            state = json.load(f)
        watermark = state.get('lastProcessedSignal')
        if watermark:
            had_watermark = True
            try:
                watermark_ts = datetime.fromisoformat(str(watermark).replace('Z', '+00:00'))
                print(f"Watermark: {watermark}")
            except ValueError:
                print("Watermark: (unrecognized format, ignoring)")
    except (OSError, json.JSONDecodeError):
        pass

if watermark_ts is None and not full_mode:
    print("Watermark: (none)")

# On a cold start (no watermark yet, no explicit --limit), fall back to the
# signal limit recorded by install.sh so the first encoding doesn't try to
# chew through the entire history.
if limit is None and not had_watermark and not full_mode and os.path.exists(limit_file):
    try:
        with open(limit_file) as f:
            raw = f.read().strip()
        if raw and raw != 'whole' and raw.isdigit():
            limit = int(raw)
            print(f"First run: applying signal limit from install.sh ({limit})")
    except OSError:
        pass

if limit:
    print(f"Limit: last {limit} signals")

# Collect all turns from all sessions
all_messages = []
session_files = glob(os.path.join(transcript_dir, '*.jsonl'))

for session_file in session_files:
    try:
        with open(session_file, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if data.get('type') != 'message':
                    continue

                msg = data.get('message', {})
                role = msg.get('role', '')
                if role not in ('user', 'assistant'):
                    continue

                ts_str = data.get('timestamp', '')
                if not ts_str:
                    continue

                try:
                    ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                except ValueError:
                    continue

                if not full_mode and watermark_ts and ts <= watermark_ts:
                    continue

                # Extract text content
                content = msg.get('content', [])
                text = ''
                if isinstance(content, list):
                    for item in content:
                        if isinstance(item, dict) and item.get('type') == 'text':
                            text = item.get('text', '')
                            break
                elif isinstance(content, str):
                    text = content

                # Clean up text
                text = text[:800]  # Habits care about full instructions/corrections
                text = re.sub(r'[\x00-\x1f]', ' ', text)
                text = re.sub(r'<file[^>]*>.*?</file>', '', text, flags=re.DOTALL)
                text = re.sub(r'<file[^>]*>[^<]*', '', text)
                text = re.sub(r'<media:[^>]*>', '', text)
                text = re.sub(r'\[Audio\]', '', text)
                text = re.sub(r'Transcript:', '', text)
                text = re.sub(r'[^\x20-\x7E\u00A0-\uFFFF]', '', text)
                text = re.sub(r'[\u4e00-\u9fff\u3400-\u4dbf]+', '', text)
                text = re.sub(r'\[Telegram[^\]]*\]', '', text)
                text = re.sub(r'\[message_id:[^\]]*\]', '', text)
                text = ' '.join(text.split())

                if len(text) < 8 or text.startswith('{'):
                    continue

                ascii_ratio = sum(1 for c in text if ord(c) < 128) / max(len(text), 1)
                if ascii_ratio < 0.7:
                    continue

                if text.startswith('System:') and 'Cron:' in text:
                    continue
                if '[media attached:' in text or 'To send an image back' in text:
                    continue
                if '/Users/' in text and ('/.openclaw/' in text or '/.hermes/' in text or '/media/' in text):
                    continue

                all_messages.append({
                    'id': ts_str,         # watermark-friendly: id == timestamp
                    'timestamp': ts_str,
                    'role': role,
                    'text': text,
                    'ts_parsed': ts,
                })
    except OSError:
        continue

# Sort by timestamp
all_messages.sort(key=lambda x: x['ts_parsed'])

if limit and len(all_messages) > limit:
    all_messages = all_messages[-limit:]

with open(output_file, 'w', encoding='utf-8') as f:
    for msg in all_messages:
        out = {
            'id': msg['id'],
            'timestamp': msg['timestamp'],
            'role': msg['role'],
            'text': msg['text'],
        }
        f.write(json.dumps(out, ensure_ascii=False) + '\n')

print(f"Wrote {len(all_messages)} signals to {output_file}")
if all_messages:
    print(f"Latest signal: {all_messages[-1]['timestamp']}")
PYTHON_SCRIPT
