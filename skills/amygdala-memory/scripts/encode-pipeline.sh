#!/bin/bash
# encode-pipeline.sh — Amygdala emotional encoding with LLM detection
#
# Pipeline:
# 1. Preprocess transcript → emotional-signals.jsonl
# 2. Rule-based emotional scoring
# 3. Prepare for LLM semantic emotional detection
#
# Usage: ./encode-pipeline.sh [--no-spawn]
#
# Environment:
#   WORKSPACE - OpenClaw workspace (default: ~/.hermes/workspace)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNALS_FILE="$WORKSPACE/memory/emotional-signals.jsonl"
PENDING_FILE="$WORKSPACE/memory/pending-emotions.json"
NO_SPAWN="${1:-}"

echo "🎭 AMYGDALA ENCODING PIPELINE"
echo "============================="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 1: Run preprocess
# ═══════════════════════════════════════════════════════════════
echo "📥 Step 1: Preprocessing emotional signals..."
"$SKILL_DIR/scripts/preprocess-emotions.sh"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 2: Check for signals
# ═══════════════════════════════════════════════════════════════
if [ ! -f "$SIGNALS_FILE" ] || [ ! -s "$SIGNALS_FILE" ]; then
    echo "✅ No emotional signals to process. Done."
    exit 0
fi

SIGNAL_COUNT=$(wc -l < "$SIGNALS_FILE" | tr -d ' ')
echo "📊 Step 2: Found $SIGNAL_COUNT emotional signals"

if [ "$SIGNAL_COUNT" -eq 0 ]; then
    echo "✅ No new signals. Done."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: Rule-based emotional scoring + prepare for LLM
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🔄 Step 3: Scoring emotional signals..."

# Integrative State Layer: noradrenaline amplifies emotional intensity
NEURO_NA=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get noradrenaline 2>/dev/null || echo "0.5")
export NEURO_NA

python3 << 'PYTHON'
import json
import os
import re
from datetime import datetime

WORKSPACE = os.environ.get('WORKSPACE', os.path.expanduser('~/.hermes/workspace'))
SIGNALS_FILE = f"{WORKSPACE}/memory/emotional-signals.jsonl"
STATE_FILE = f"{WORKSPACE}/memory/emotional-state.json"
PENDING_FILE = f"{WORKSPACE}/memory/pending-emotions.json"

# Load signals
signals = []
with open(SIGNALS_FILE, 'r') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                signals.append(json.loads(line))
            except:
                pass

# Emotional patterns for scoring
emotion_patterns = {
    'joy': ['happy', 'excit', 'joy', 'love', 'great', 'awesome', 'amazing', 'wonderful', 'fantastic', '🎉', '😊', '❤️'],
    'sadness': ['sad', 'disappoint', 'miss', 'lost', 'lonely', 'depressed', 'hurt', 'sorry', '😢', '💔'],
    'anger': ['angry', 'frustrat', 'annoy', 'furious', 'upset', 'hate', 'damn', 'ugh'],
    'fear': ['scared', 'afraid', 'worried', 'anxious', 'nervous', 'fear', 'terrif', 'panic'],
    'curiosity': ['curious', 'interest', 'wonder', 'fascin', 'intrigu', 'explore', 'learn', '🤔'],
    'connection': ['together', 'we ', 'us ', 'our ', 'bond', 'close', 'trust', 'friend', 'love you', 'thank you'],
    'accomplishment': ['done', 'complet', 'finish', 'success', 'works', 'fixed', 'solved', 'achieved', '✅'],
    'fatigue': ['tired', 'exhaust', 'drain', 'sleep', 'rest', 'overwhelm', 'burned out'],
}

def score_emotion(text):
    """Detect emotions in text"""
    text_lower = text.lower()
    detected = []
    
    for emotion, keywords in emotion_patterns.items():
        for kw in keywords:
            if kw in text_lower:
                detected.append(emotion)
                break
    
    return list(set(detected))

def estimate_intensity(text, emotions):
    """Estimate emotional intensity 0.0-1.0"""
    # More exclamation marks = higher intensity
    excl_count = text.count('!')
    caps_ratio = sum(1 for c in text if c.isupper()) / max(len(text), 1)
    
    base = 0.5
    if excl_count > 0:
        base += min(excl_count * 0.1, 0.3)
    if caps_ratio > 0.3:
        base += 0.2
    if len(emotions) > 1:
        base += 0.1
    
    return min(base, 1.0)

# Process signals
pending = []
skipped = 0
today = datetime.now().strftime('%Y-%m-%d')

for sig in signals:
    text = sig.get('text', '')
    role = sig.get('role', 'user')
    sig_id = sig.get('id', '')
    
    # Skip very short or system-like messages
    if len(text) < 20:
        skipped += 1
        continue
    
    # Detect emotions
    emotions = score_emotion(text)
    
    if not emotions:
        skipped += 1
        continue
    
    intensity = estimate_intensity(text, emotions)
    na = float(os.environ.get('NEURO_NA', '0.5'))
    intensity *= (1.0 + 0.3 * (na - 0.5))   # arousal amplifies emotional intensity
    
    pending.append({
        "id": sig_id,
        "text": text[:500],
        "role": role,
        "detected_emotions": emotions,
        "estimated_intensity": round(intensity, 2),
        "timestamp": sig.get('timestamp', today)
    })

# Save pending for LLM analysis
with open(PENDING_FILE, 'w') as f:
    json.dump({"pending": pending, "created": today}, f, indent=2)

print(f"   Pending for LLM analysis: {len(pending)}")
print(f"   Skipped (no clear emotion): {skipped}")

# Show sample
if pending:
    print(f"\n   Sample detected:")
    for p in pending[:3]:
        print(f"      {p['detected_emotions']}: {p['text'][:60]}...")
PYTHON

# Check if we have pending emotions
PENDING_COUNT=$(PENDING_FILE="$PENDING_FILE" python3 -c "import os
import json; d=json.load(open(os.environ['PENDING_FILE'])); print(len(d.get('pending',[])))" 2>/dev/null || echo "0")

if [ "$PENDING_COUNT" -eq 0 ]; then
    echo ""
    echo "✅ No emotional signals need LLM analysis. Updating watermark..."
    "$SKILL_DIR/scripts/update-watermark.sh" --from-signals
    # Regenerate dashboard
    "$SKILL_DIR/scripts/sync-state.sh" 2>/dev/null || true
    exit 0
fi

echo ""
echo "📝 $PENDING_COUNT signals pending LLM emotional analysis"

if [ "$NO_SPAWN" = "--no-spawn" ]; then
    echo "⏭️  Skipping spawn (--no-spawn flag)"
    exit 0
fi

echo ""
echo "✅ Pipeline phase 1 complete. Sub-agent will handle emotional detection."
