#!/bin/bash
# preprocess-mentions.sh — Scan transcripts for relationship-relevant signals:
# new people/agents mentioned, trust/affinity-relevant moments, things promised.
# Usage: preprocess-mentions.sh [--full]
set -e
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
AGENT_ID="${AGENT_ID:-main}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-$HOME/.hermes/sessions}"
OUTPUT="$WORKSPACE/memory/social-signals.jsonl"
WATERMARK_FILE="$WORKSPACE/memory/social-watermark.json"

FULL_MODE=false
[ "$1" = "--full" ] && FULL_MODE=true

WATERMARK=""
if [ "$FULL_MODE" = false ] && [ -f "$WATERMARK_FILE" ]; then
    WATERMARK=$(jq -r '.lastProcessedSignal // empty' "$WATERMARK_FILE" 2>/dev/null || echo "")
fi

SESSION_FILE=$(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
[ -z "$SESSION_FILE" ] && { echo "No session transcript found"; exit 1; }

echo "Processing: $SESSION_FILE"

OUTPUT="$OUTPUT" SESSION_FILE="$SESSION_FILE" WATERMARK="$WATERMARK" python3 -c "import os

import json, re

session_file = os.environ['SESSION_FILE']
output_file = os.environ['OUTPUT']
watermark = os.environ['WATERMARK'] if os.environ['WATERMARK'] else None

signals = []
found_watermark = False if watermark else True

social_keywords = [
    'i promise', \"i'll get back to\", 'remind me to', 'owe you', 'thank you for',
    'appreciate', 'trust', 'i feel like you', 'my friend', 'reach out to',
    'introduce', 'met someone', 'another agent', 'other ai', 'moltbook',
]

with open(session_file, 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue

        msg_id = data.get('id', '')
        if watermark and msg_id == watermark:
            found_watermark = True
            continue
        if not found_watermark:
            continue
        if data.get('type') != 'message':
            continue

        msg = data.get('message', {})
        role = msg.get('role', '')
        if role not in ('user', 'assistant'):
            continue

        content = msg.get('content', [])
        text = ''
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get('type') == 'text':
                    text = item.get('text', '')
                    break
        elif isinstance(content, str):
            text = content

        text = text[:600]
        text = re.sub(r'[\x00-\x1f]', ' ', text)
        text = ' '.join(text.split())
        if len(text) < 15:
            continue

        text_lower = text.lower()
        if any(kw in text_lower for kw in social_keywords):
            signals.append({'id': msg_id, 'timestamp': data.get('timestamp',''), 'role': role, 'text': text})

with open(output_file, 'w', encoding='utf-8') as f:
    for sig in signals:
        f.write(json.dumps(sig, ensure_ascii=False) + '\n')

print(f'Wrote {len(signals)} social signals to {output_file}')
"
