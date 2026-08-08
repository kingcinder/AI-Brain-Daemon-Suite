#!/usr/bin/env bash
# anterior-cingulate-memory/install.sh
# Installs the anterior-cingulate-memory skill into the Hermes workspace.
# Usage: ./install.sh [--with-cron]

set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
MEMORY_DIR="$WORKSPACE/memory"
STATE_FILE="$MEMORY_DIR/conflict-state.json"
INJECT_FILE="$WORKSPACE/ACC_CONFLICT_STATE.md"
LOG_FILE="$MEMORY_DIR/brain-events.jsonl"

WITH_CRON=false
for arg in "$@"; do
  [[ "$arg" == "--with-cron" ]] && WITH_CRON=true
done

echo "⚡ Installing anterior-cingulate-memory..."
echo "   Workspace: $WORKSPACE"

# ── 1. Create directories ─────────────────────────────────────────────────────
mkdir -p "$MEMORY_DIR"

# ── 2. Create initial state file (no-op if already exists) ───────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$STATE_FILE" << STATEEOF
{
  "version": "1.0",
  "lastUpdated": "$NOW",
  "conflictLoad": 0.2,
  "baseline": {
    "conflictLoad": 0.2
  },
  "activeConflicts": {},
  "attentionFlags": [],
  "uncertaintyZones": {},
  "resolvedConflicts": [],
  "stats": {
    "totalConflictsLogged": 0,
    "totalResolved": 0,
    "totalAttentionFlags": 0,
    "encodingRuns": 0
  }
}
STATEEOF
  echo "   ✅ Created conflict-state.json (baseline values)"
else
  echo "   ℹ️  conflict-state.json already exists — skipping init"
fi

# ── 3. Touch brain-events log ─────────────────────────────────────────────────
if [[ ! -f "$LOG_FILE" ]]; then
  touch "$LOG_FILE"
  echo "   ✅ Created brain-events.jsonl"
fi

# ── 4. Generate ACC_CONFLICT_STATE.md ─────────────────────────────────────────
"$SKILL_DIR/scripts/sync-state.sh"
echo "   ✅ Generated ACC_CONFLICT_STATE.md"

# ── 5. Optional cron setup ────────────────────────────────────────────────────
if [[ "$WITH_CRON" == true ]]; then
  echo ""
  echo "Setting up Hermes cron jobs..."

  if ! command -v hermes &> /dev/null; then
    echo "⚠️  'hermes' not in PATH. Add these cron jobs manually:"
    echo ""
    echo "hermes cron create '0 */4 * * *' '⚡ Run conflict load decay: Run $SKILL_DIR/scripts/decay-load.sh and sync state' --name acc-conflict-decay"
    echo "hermes cron create '50 0,3,6,9,12,15,18,21 * * *' 'Run ACC conflict encoding: Run encode-pipeline.sh, detect conflicts, update state.' --name acc-conflict-encoding"
  else
    echo "   Creating acc-conflict-decay..."
    hermes cron create '0 */4 * * *' "⚡ Run conflict load decay: Run $SKILL_DIR/scripts/decay-load.sh and report results" --name acc-conflict-decay 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"

    echo "   Creating acc-conflict-encoding..."
    hermes cron create '50 0,3,6,9,12,15,18,21 * * *' "Run ACC conflict encoding: 1) Run encode-pipeline.sh 2) Detect conflicts and uncertainty 3) Update state 4) Update watermark 5) Sync state" --name acc-conflict-encoding 2>/dev/null && echo "   ✅ Created" || echo "   ⏭️  Already exists"
  fi
fi

echo ""
echo "⚡ anterior-cingulate-memory ready!"
echo ""
echo "   State:     $STATE_FILE"
echo "   Inject:    $INJECT_FILE"
echo ""
echo "   Quick commands:"
echo "   ./scripts/load-state.sh               # human-readable state"
echo "   ./scripts/log-conflict.sh --help      # log a conflict"
echo "   ./scripts/resolve-conflict.sh --help  # resolve a conflict"
echo "   ./scripts/flag-attention.sh --help    # flag a topic"
