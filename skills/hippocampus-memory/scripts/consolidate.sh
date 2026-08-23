#!/bin/bash
# Memory consolidation helper
# Reviews recent daily notes and suggests what to consolidate
#
# Environment:
#   WORKSPACE - OpenClaw workspace directory (default: ~/.hermes/workspace)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
MEMORY_DIR="$WORKSPACE/memory"

# ── Closed-loop: after consolidation, signal PFC to reflect on what changed ──
PENDING_REFLECTION="$WORKSPACE/memory/.pending-reflection"

echo "🧠 Memory Consolidation"
echo "======================="
echo ""

# Find daily notes from the past week
echo "📅 Recent daily notes:"
find "$MEMORY_DIR" -maxdepth 1 -name "202*.md" -mtime -7 -exec basename {} \; | sort -r

echo ""
echo "---"
echo ""
echo "Consolidation checklist:"
echo ""
echo "1. Review each daily note for:"
echo "   - [User] facts → memory/user/*.md"
echo "   - [Self] insights → memory/self/*.md"
echo "   - [Relationship] moments → memory/relationship/*.md"
echo "   - [World] knowledge → memory/world/*.md"
echo ""
echo "2. Update MEMORY.md with distilled insights"
echo ""
echo "3. Check for outdated information to archive"
echo ""
echo "4. Look for patterns across days"
echo ""
echo "Files to update:"
echo "  - $WORKSPACE/MEMORY.md (long-term)"
echo "  - $MEMORY_DIR/user/*.md"
echo "  - $MEMORY_DIR/self/*.md"  
echo "  - $MEMORY_DIR/relationship/*.md"
echo "  - $MEMORY_DIR/world/*.md"

# ═══════════════════════════════════════════════════════════════════════
# CLS replay pass (McClelland, McNaughton & O'Reilly; Marr 1971; Buzsáki)
# The consolidation job actually CONSOLIDATES: it replays a sample of the
# most recent episodic traces (the fast hippocampal store) and, grouping
# them by domain/category theme, slowly strengthens a cortical aggregate
# (memory/cortical.json) — episodic → semantic transfer via offline replay.
# Each replayed trace adds a small weight increment to its theme, so
# repeatedly-replayed themes drift toward stable cortex-level knowledge
# while the episodic traces themselves are never touched. Purely additive.
# ═══════════════════════════════════════════════════════════════════════
INDEX_FILE="$MEMORY_DIR/index.json"
CORTICAL_FILE="$MEMORY_DIR/cortical.json"
echo ""
echo "🔄 Replay pass (episodic → cortical consolidation):"
if [ ! -f "$INDEX_FILE" ]; then
    echo "   (no episodic index at $INDEX_FILE — nothing to replay)"
else
    python3 - "$INDEX_FILE" "$CORTICAL_FILE" << 'PYTHON' || echo "   (replay pass failed — continuing)"
import json, os, sys
from datetime import datetime, timezone

index_path, cortical_path = sys.argv[1], sys.argv[2]
try:
    with open(index_path) as f:
        index = json.load(f)
    memories = index.get('memories', [])
except Exception:
    memories = []

if not memories:
    print("   (no episodic traces in index — nothing to replay)")
    sys.exit(0)

# Sample the most recently accessed / created traces (max 8 per pass)
ordered = sorted(
    memories,
    key=lambda m: (m.get('lastAccessed', ''), m.get('created', '')),
    reverse=True,
)[:8]

try:
    with open(cortical_path) as f:
        cortical = json.load(f)
except Exception:
    cortical = {"version": 1, "themes": {}, "replays": []}

themes = cortical.setdefault('themes', {})
replays = cortical.setdefault('replays', [])
now = datetime.now(timezone.utc).isoformat()
replayed = 0
for m in ordered:
    theme = f"{m.get('domain', 'unknown')}/{m.get('category', 'general')}"
    t = themes.setdefault(theme, {"weight": 0.0, "traceCount": 0, "lastReplayed": None})
    t["weight"] = round(t["weight"] + 0.1, 4)   # slow cortical strengthening
    t["traceCount"] = t.get("traceCount", 0) + 1
    t["lastReplayed"] = now
    replays.append({"memory_id": m.get('id'), "theme": theme, "at": now})
    replayed += 1

cortical['replays'] = replays[-50:]
cortical['lastReplayAt'] = now
tmp = cortical_path + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(cortical, f, indent=2)
os.rename(tmp, cortical_path)

for theme, t in sorted(themes.items()):
    print(f"   theme {theme}: weight={t['weight']:.2f} (traces replayed: {t['traceCount']})")
print(f"   Replayed {replayed} episodic trace(s) → cortical themes strengthened.")
PYTHON
fi

# ── Closed-loop: signal PFC that consolidation happened — the next executive
#    cycle's isolated-reflect.sh will pick up this marker and trigger a
#    reflection pass over the freshly consolidated memory. ────────────────────
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$PENDING_REFLECTION"
# Set marker for the run-cycle.sh wrapper to check
echo "🧠 Consolidation complete — PFC reflection marker set."
