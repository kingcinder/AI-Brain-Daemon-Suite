#!/usr/bin/env bash
# scripts/preprocess-exchanges.sh — Extract conversation exchanges from transcript
# for conflict analysis. Outputs a JSON array of {role, content} pairs.
#
# Respects the encode watermark so only new exchanges are processed.
#
# Usage:
#   ./preprocess-exchanges.sh <transcript_file> [--max-exchanges N]
#   Output: JSON to stdout

set -e

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TRANSCRIPT="${1:-}"
MAX_EXCHANGES="${2:-30}"
if [[ "$2" == "--max-exchanges" ]]; then
  MAX_EXCHANGES="${3:-30}"
fi

# ── Default: look for most recent transcript in workspace ─────────────────────
if [[ -z "$TRANSCRIPT" ]]; then
  TRANSCRIPT=$(find "$WORKSPACE" -name "*.transcript.json" -o -name "*.chat.json" \
    2>/dev/null | sort -t_ -k2 -rn | head -1)
fi

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  # Fall back to any .jsonl conversation log
  TRANSCRIPT=$(find "$WORKSPACE" -name "conversation*.jsonl" 2>/dev/null | head -1)
fi

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  echo "[]"
  exit 0
fi

# ── Get watermark ─────────────────────────────────────────────────────────────
WATERMARK=$("$SKILL_DIR/scripts/update-watermark.sh" --get)

# ── Extract exchanges ─────────────────────────────────────────────────────────
# Handle both JSON array of messages and JSONL formats
if TRANSCRIPT="$TRANSCRIPT" python3 -c "import os
import json, sys; json.load(open(os.environ['TRANSCRIPT']))" 2>/dev/null; then
  # JSON array format
  MAX_EXCHANGES="$MAX_EXCHANGES" TRANSCRIPT="$TRANSCRIPT" WATERMARK="$WATERMARK" python3 << 'PYEOF'
import os
import json, sys

with open(os.environ['TRANSCRIPT']) as f:
    data = json.load(f)

# Support top-level array or {messages: [...]}
messages = data if isinstance(data, list) else data.get('messages', [])

# Apply watermark
start = int(os.environ['WATERMARK'])
messages = messages[start:]

# Extract up to max_exchanges, focusing on human+assistant pairs
exchanges = []
for msg in messages[:int(os.environ['MAX_EXCHANGES'])]:
    role = msg.get('role', msg.get('type', 'unknown'))
    content = msg.get('content', msg.get('text', ''))
    if isinstance(content, list):
        content = ' '.join(
            c.get('text', '') for c in content if c.get('type') == 'text'
        )
    if content and role in ('user', 'human', 'assistant'):
        exchanges.append({'role': role, 'content': str(content)[:2000]})

print(json.dumps(exchanges))
PYEOF
else
  # JSONL format
  MAX_EXCHANGES="$MAX_EXCHANGES" TRANSCRIPT="$TRANSCRIPT" WATERMARK="$WATERMARK" python3 << 'PYEOF'
import os
import json, sys

exchanges = []
start = int(os.environ['WATERMARK'])
line_num = 0
with open(os.environ['TRANSCRIPT']) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        if line_num < start:
            line_num += 1
            continue
        try:
            msg = json.loads(line)
            role = msg.get('role', 'unknown')
            content = msg.get('content', '')
            if isinstance(content, list):
                content = ' '.join(c.get('text','') for c in content if c.get('type')=='text')
            if content and role in ('user', 'human', 'assistant'):
                exchanges.append({'role': role, 'content': str(content)[:2000]})
        except Exception:
            pass
        line_num += 1
        if len(exchanges) >= int(os.environ['MAX_EXCHANGES']):
            break

print(json.dumps(exchanges))
PYEOF
fi
