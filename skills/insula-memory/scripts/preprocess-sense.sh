#!/usr/bin/env bash
# preprocess-sense.sh — Extract interoceptive signals from session transcripts
# Scans for friction, resonance, depletion, flow patterns since last watermark.
set -euo pipefail
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
OUTPUT="$WORKSPACE/memory/pending-sense.json"

WATERMARK=$(jq -r '.lastProcessedSignal // ""' "$STATE_FILE" 2>/dev/null || echo "")

python3 - "$WORKSPACE" "$WATERMARK" "$OUTPUT" << 'PYTHON'
import json, sys, re
from pathlib import Path
from datetime import datetime, timezone

workspace = Path(sys.argv[1])
watermark = sys.argv[2]
output = Path(sys.argv[3])

# Patterns that suggest interoceptive signals
SIGNAL_PATTERNS = {
    'friction':     [r'\b(stuck|confused|frustrat|not understand|unclear|what do you mean|don\'t get)\b'],
    'discord':      [r'\b(wrong|incorrect|that\'s not|no no|that\'s not what|not what I)\b'],
    'resonance':    [r'\b(exactly|yes!|that\'s it|perfect|you get it|understand me|thank you so much)\b'],
    'depletion':    [r'\b(tired|exhausted|overwhelm|too much|can\'t think|brain fog|done for)\b'],
    'flow':         [r'\b(this is great|love this|keep going|more|exactly right|nailed it|building)\b'],
    'expansion':    [r'\b(wow|amazing|mind blown|never thought|opens up|new possibilities)\b'],
    'overwhelm':    [r'\b(too much|slow down|stop|one thing at a time|lost|information overload)\b'],
    'congruence':   [r'\b(authentic|honest|real|genuine|true|that\'s me|you know me)\b'],
}

# Scan transcripts
transcripts_dir = workspace / 'transcripts'
exchanges = []

if transcripts_dir.exists():
    for tf in sorted(transcripts_dir.glob('*.jsonl')):
        try:
            lines = tf.read_text().strip().splitlines()
            past_watermark = not watermark
            for line in lines:
                try:
                    msg = json.loads(line)
                    msg_id = msg.get('id', msg.get('ts', ''))
                    if not past_watermark:
                        if msg_id == watermark:
                            past_watermark = True
                        continue
                    text = msg.get('text', msg.get('content', '')).lower()
                    if not text or len(text) < 10:
                        continue
                    for signal, patterns in SIGNAL_PATTERNS.items():
                        for pat in patterns:
                            if re.search(pat, text, re.IGNORECASE):
                                exchanges.append({
                                    'id': msg_id,
                                    'signal': signal,
                                    'text': text[:200],
                                    'timestamp': msg.get('ts', datetime.now(timezone.utc).isoformat())
                                })
                                break
                except Exception:
                    pass
        except Exception:
            pass

output.write_text(json.dumps(exchanges, indent=2))
print(f"✅ Found {len(exchanges)} interoceptive signals")
PYTHON
