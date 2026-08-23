#!/bin/bash
# cleanup-all-skills.sh — Standardized per-skill state removal (Initiative 9).
#
# Runs every deployed skill's `install.sh --uninstall --yes` so each skill
# removes exactly the state files its manifest declares. Called by the
# central uninstall.sh before the workspace is removed, and by users who
# want to reset brain state only.
#
# Usage: cleanup-all-skills.sh [--workspace PATH] [--yes]
#   --yes: skip per-skill confirmation (passed through to each installer).

set -euo pipefail

WS="${WORKSPACE:-$HOME/.hermes/workspace}"
YES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WS="$2"; shift 2 ;;
    --yes|-y) YES="--yes"; shift ;;
    *) shift ;;
  esac
done

SKILLS_DIR="$WS/skills"
[ -d "$SKILLS_DIR" ] || { echo "cleanup-all-skills.sh: no skills dir at $SKILLS_DIR" >&2; exit 1; }

echo "--- Removing per-skill state ---"
OK=0
FAILED=0
SKIPPED=0

for INSTALLER in "$SKILLS_DIR"/*/install.sh; do
  [ -x "$INSTALLER" ] || { SKIPPED=$((SKIPPED+1)); continue; }
  SKILL_NAME=$(basename "$(dirname "$INSTALLER")")
  if WORKSPACE="$WS" bash "$INSTALLER" --uninstall $YES >/tmp/skill-cleanup-$$.log 2>&1; then
    OK=$((OK+1))
  else
    echo "  WARN: $SKILL_NAME --uninstall failed (see /tmp/skill-cleanup-$$.log)" >&2
    FAILED=$((FAILED+1))
  fi
done

rm -f /tmp/skill-cleanup-$$.log
echo "--- Per-skill cleanup: $OK ok, $FAILED failed, $SKIPPED skipped (no installer) ---"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
