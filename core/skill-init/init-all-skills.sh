#!/bin/bash
# init-all-skills.sh — Standardized per-skill initialization (Initiative 9).
#
# Runs every deployed skill's install.sh (init mode, no args) so each skill
# creates its state files with defaults. Called by the central install.sh
# after deploy and by users who want to re-init state only.
#
# Usage: init-all-skills.sh [--workspace PATH] [--yes]
#   --yes: never prompts (the per-skill installers are non-interactive by
#          default; this flag is reserved for future skill installers that
#          may ask).

set -euo pipefail

WS="${WORKSPACE:-$HOME/.hermes/workspace}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WS="$2"; shift 2 ;;
    --yes|-y) shift ;;
    *) shift ;;
  esac
done

SKILLS_DIR="$WS/skills"
[ -d "$SKILLS_DIR" ] || { echo "init-all-skills.sh: no skills dir at $SKILLS_DIR" >&2; exit 1; }

echo "--- Initializing per-skill state ---"
OK=0
FAILED=0
SKIPPED=0

for INSTALLER in "$SKILLS_DIR"/*/install.sh; do
  [ -x "$INSTALLER" ] || { SKIPPED=$((SKIPPED+1)); continue; }
  SKILL_NAME=$(basename "$(dirname "$INSTALLER")")
  # Run with the deployed workspace. Each installer is non-interactive in
  # init mode (they only create state files / chmod scripts).
  if WORKSPACE="$WS" bash "$INSTALLER" >/tmp/skill-init-$$.log 2>&1; then
    OK=$((OK+1))
  else
    echo "  WARN: $SKILL_NAME install.sh failed (see /tmp/skill-init-$$.log)" >&2
    FAILED=$((FAILED+1))
  fi
done

rm -f /tmp/skill-init-$$.log
echo "--- Per-skill init: $OK ok, $FAILED failed, $SKIPPED skipped (no installer) ---"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
