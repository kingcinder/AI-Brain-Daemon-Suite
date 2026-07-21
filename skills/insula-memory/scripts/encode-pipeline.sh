#!/usr/bin/env bash
# encode-pipeline.sh — Full interoceptive encoding pipeline
# 1. Preprocess transcripts for signals
# 2. Apply rule-based signals directly (no LLM needed for insula)
# 3. Sync state → INSULA_STATE.md
# 4. Update dashboard
# 5. Log event
set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$WORKSPACE/memory/interoceptive-state.json"
PENDING="$WORKSPACE/memory/pending-sense.json"

echo "🌡️ Insula Encode Pipeline — $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

[ ! -f "$STATE_FILE" ] && echo "Not installed. Run ./install.sh first." && exit 1

# Step 1: Preprocess
echo "Step 1: Preprocessing transcripts..."
"$SCRIPT_DIR/preprocess-sense.sh"

# Step 2: Apply detected signals
if [ -f "$PENDING" ]; then
  COUNT=$(jq 'length' "$PENDING")
  echo "Step 2: Applying $COUNT signals..."
  if [ "$COUNT" -gt 0 ]; then
    python3 - "$PENDING" "$SCRIPT_DIR" << 'PYTHON'
import json, sys, subprocess
from pathlib import Path
from collections import Counter

pending = json.load(open(sys.argv[1]))
script_dir = sys.argv[2]

# Aggregate signals — find the most common, apply weighted
signal_counts = Counter(e.get('signal') for e in pending)
total = len(pending)

for signal, count in signal_counts.most_common(4):
    # Scale intensity: more occurrences = higher intensity (max 0.8)
    intensity = min(0.8, 0.3 + (count / total) * 0.5)
    source = f"auto-detected: {count}/{total} exchanges"
    subprocess.run([
        f"{script_dir}/update-state.sh",
        "--signal", signal,
        "--intensity", f"{intensity:.2f}",
        "--source", source
    ], check=False)

# Advance watermark to last signal
if pending:
    last_id = pending[-1].get('id', pending[-1].get('timestamp', ''))
    if last_id:
        subprocess.run([f"{script_dir}/update-watermark.sh", last_id], check=False)
PYTHON
  fi
fi

# Step 3: Decay (partial — encoding also applies gentle drift toward baseline)
echo "Step 3: Applying gentle decay..."
"$SCRIPT_DIR/decay-sense.sh" > /dev/null 2>&1 || true

# Step 4: Sync markdown
echo "Step 4: Syncing INSULA_STATE.md..."
"$SCRIPT_DIR/sync-state.sh"

# Step 5: Dashboard
echo "Step 5: Updating dashboard..."
"$SCRIPT_DIR/generate-dashboard.sh" > /dev/null 2>&1 || true

# Step 6: Log event
SIGNALS_FOUND=$(jq 'length' "$PENDING" 2>/dev/null || echo 0)
GUT=$(jq -r '.channels.gutSignal // 0' "$STATE_FILE")
LOAD=$(jq -r '.channels.cognitiveLoad // 0.3' "$STATE_FILE")
"$SCRIPT_DIR/log-event.sh" encoding signals_found="$SIGNALS_FOUND" gutSignal="$GUT" cognitiveLoad="$LOAD"

echo "✅ Insula pipeline complete"
