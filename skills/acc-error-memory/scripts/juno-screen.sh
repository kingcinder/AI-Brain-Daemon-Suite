#!/bin/bash
# ACC Juno Screening — Juno-classified error signal confirmation
# Juno herself confirms whether regex-filtered exchanges are actual errors,
# through the helm queue (juno-ask.sh). No external model CLI is involved.
#
# Usage:
#   juno-screen.sh <pending-errors.json>
#
# Environment:
#   JUNO_ASK  Path to juno-ask.sh (default: resolved from the workspace's
#             prefrontal-cortex-memory / anterior-cingulate-memory scripts)
#
# Output: Filtered JSON array to stdout (only confirmed errors)
# Logs screening stats to stderr

set -e

INPUT_FILE="${1:?Usage: juno-screen.sh <pending-errors.json>}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "[]"
    exit 0
fi

export INPUT_FILE

python3 << 'PYTHON'
import json
import subprocess
import sys
import os

input_file = os.environ.get('INPUT_FILE', '')

try:
    with open(input_file) as f:
        exchanges = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    print("[]")
    sys.exit(0)

if not isinstance(exchanges, list) or len(exchanges) == 0:
    print("[]")
    sys.exit(0)

PROMPT_TEMPLATE = """You are classifying a conversation exchange. The user message follows an assistant message.

Assistant said:
{assistant_text}

User replied:
{user_text}

Is the user's message a correction, complaint, or expression of frustration with the assistant? Answer YES or NO only."""

def find_juno_ask():
    """Resolve juno-ask.sh: env override, then the workspace's copies."""
    env = os.environ.get('JUNO_ASK', '')
    if env and os.access(env, os.X_OK):
        return env
    candidates = []
    ws = os.environ.get('WORKSPACE', '')
    if ws:
        candidates += [
            os.path.join(ws, 'skills/prefrontal-cortex-memory/scripts/juno-ask.sh'),
            os.path.join(ws, 'skills/anterior-cingulate-memory/scripts/juno-ask.sh'),
        ]
    home_ws = os.path.expanduser('~/.juno-brain/workspace')
    candidates += [
        os.path.join(home_ws, 'skills/prefrontal-cortex-memory/scripts/juno-ask.sh'),
        os.path.join(home_ws, 'skills/anterior-cingulate-memory/scripts/juno-ask.sh'),
    ]
    for c in candidates:
        if os.access(c, os.X_OK):
            return c
    return None

JUNO_ASK = find_juno_ask()

def classify_exchange(prompt):
    """Ask Juno. Returns her answer text, or None if she could not answer."""
    if not JUNO_ASK:
        return None
    try:
        result = subprocess.run(
            ['bash', JUNO_ASK, '--user', prompt, '--timeout', '120'],
            capture_output=True, text=True, timeout=150
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().upper()
    except subprocess.TimeoutExpired:
        print("Juno screening timed out", file=sys.stderr)
    except Exception as e:
        print(f"Juno screening error: {e}", file=sys.stderr)
    return None

confirmed = []
stats = {}

for exchange in exchanges:
    assistant_text = exchange.get('assistant_text', '')[:500]
    user_text = exchange.get('user_text', '')[:500]

    if not user_text:
        continue

    prompt = PROMPT_TEMPLATE.format(
        assistant_text=assistant_text,
        user_text=user_text
    )

    answer = classify_exchange(prompt)

    if answer:
        stats['juno'] = stats.get('juno', 0) + 1
        if 'YES' in answer:
            confirmed.append(exchange)
    else:
        # Juno could not answer — keep the exchange as safety fallback
        print("Juno unavailable, keeping exchange as fallback", file=sys.stderr)
        confirmed.append(exchange)
        stats['fallback'] = stats.get('fallback', 0) + 1

total = len(exchanges)
kept = len(confirmed)
print(json.dumps(confirmed, indent=2), file=sys.stdout)

stats_str = ", ".join(f"{k}:{v}" for k, v in sorted(stats.items()))
print(f"Juno screening: {total} → {kept} confirmed errors ({stats_str})", file=sys.stderr)
PYTHON
