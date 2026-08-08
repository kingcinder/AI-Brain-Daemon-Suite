#!/usr/bin/env bash
# scripts/log-conflict.sh — Log a detected conflict and raise conflict load
#
# Usage:
#   ./log-conflict.sh \
#     --type <factual|instruction|context|uncertainty|intent|knowledge_gap> \
#     --description "..." \
#     [--severity <low|moderate|high>] \
#     [--intensity <0.0-1.0>] \
#     [--resolution-hint "..."]
#
# Conflict types:
#   factual       — Contradictory facts in conversation
#   instruction   — Conflicting or ambiguous user instructions
#   context       — Missing or unclear context
#   uncertainty   — High uncertainty about a claim
#   intent        — Ambiguous user intent
#   knowledge_gap — Agent's knowledge insufficient to proceed

set -e

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"

# ── Defaults ──────────────────────────────────────────────────────────────────
TYPE=""
DESCRIPTION=""
SEVERITY="moderate"
INTENSITY=""
RESOLUTION_HINT=""

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)         TYPE="$2";            shift 2 ;;
    --description)  DESCRIPTION="$2";    shift 2 ;;
    --severity)     SEVERITY="$2";       shift 2 ;;
    --intensity)    INTENSITY="$2";      shift 2 ;;
    --resolution-hint) RESOLUTION_HINT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
VALID_TYPES="factual instruction context uncertainty intent knowledge_gap"
if [[ -z "$TYPE" ]]; then
  echo "ERROR: --type is required" >&2; exit 1
fi
if ! echo "$VALID_TYPES" | grep -qw "$TYPE"; then
  echo "ERROR: Invalid type '$TYPE'. Valid: $VALID_TYPES" >&2; exit 1
fi
if [[ -z "$DESCRIPTION" ]]; then
  echo "ERROR: --description is required" >&2; exit 1
fi
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: conflict-state.json not found. Run ./install.sh first." >&2; exit 1
fi

# ── Serialize the read-modify-write against concurrent writers ────────────────
# (encode-pipeline spawn job, decay job, manual resolve) — same lock
# safe-write.sh takes for this state file.
exec 200>"$STATE_FILE.lock"
flock 200

# ── Derive intensity from severity if not explicitly set ──────────────────────
if [[ -z "$INTENSITY" ]]; then
  case "$SEVERITY" in
    low)      INTENSITY="0.35" ;;
    moderate) INTENSITY="0.65" ;;
    high)     INTENSITY="0.90" ;;
    *)        INTENSITY="0.50" ;;
  esac
fi

# ── Generate conflict ID ───────────────────────────────────────────────────────
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EPOCH=$(date +%s)
CONFLICT_ID="${TYPE}_${EPOCH}"

# ── Calculate new load ────────────────────────────────────────────────────────
CURRENT_LOAD=$(jq -r '.conflictLoad' "$STATE_FILE")
BOOST=$(echo "$INTENSITY * 0.15" | bc -l)
NEW_LOAD=$(echo "if ($CURRENT_LOAD + $BOOST > 1.0) 1.0 else ($CURRENT_LOAD + $BOOST)" | bc -l)
NEW_LOAD=$(printf "%.4f" "$NEW_LOAD")

# ── Write to state ────────────────────────────────────────────────────────────
UPDATED=$(jq \
  --arg id "$CONFLICT_ID" \
  --arg type "$TYPE" \
  --arg severity "$SEVERITY" \
  --argjson intensity "$INTENSITY" \
  --arg description "$DESCRIPTION" \
  --arg hint "$RESOLUTION_HINT" \
  --arg now "$NOW" \
  --argjson newLoad "$NEW_LOAD" \
  '
  .conflictLoad = $newLoad |
  .lastUpdated = $now |
  .activeConflicts[$id] = {
    type: $type,
    severity: $severity,
    intensity: $intensity,
    description: $description,
    resolutionHint: $hint,
    firstSeen: $now,
    lastSeen: $now
  } |
  .stats.totalConflictsLogged += 1
  ' "$STATE_FILE")

echo "$UPDATED" > "$STATE_FILE.tmp.$$"
mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

# ── Sync inject file ──────────────────────────────────────────────────────────
"$SKILL_DIR/scripts/sync-state.sh" --quiet

# ── Log event ─────────────────────────────────────────────────────────────────
"$SKILL_DIR/scripts/log-event.sh" \
  conflict \
  "type=$TYPE" \
  "severity=$SEVERITY" \
  "intensity=$INTENSITY" \
  "load_before=$CURRENT_LOAD" \
  "load_after=$NEW_LOAD" \
  "id=$CONFLICT_ID" 2>/dev/null || true

# ── Output ────────────────────────────────────────────────────────────────────
DELTA=$(echo "$NEW_LOAD - $CURRENT_LOAD" | bc -l)
DELTA=$(printf "+%.4f" "$DELTA")

echo "⚡ Conflict logged: $TYPE"
echo "   ID:    $CONFLICT_ID"
echo "   Load:  $CURRENT_LOAD → $NEW_LOAD ($DELTA)"
echo "   Desc:  $DESCRIPTION"
[[ -n "$RESOLUTION_HINT" ]] && echo "   Hint:  $RESOLUTION_HINT"
