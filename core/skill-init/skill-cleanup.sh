#!/bin/bash
# skill-cleanup.sh — Standardized per-skill state removal (Initiative 9).
#
# Removes exactly the state files a skill's capability-manifest.json declares
# as `state_write` outputs (memory/*.json, *.jsonl, markers). Never touches
# scripts, prompts, or any file not declared as an output.
#
# Usage:
#   skill-cleanup.sh --skill <skill-dir> --workspace <ws> [--yes]
#
# TTY-safe confirmation: refuses to remove anything without --yes when stdin
# is not a TTY (CI safety), prompts when it is.

set -euo pipefail

SKILL_DIR=""
WS=""
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill) SKILL_DIR="$2"; shift 2 ;;
    --workspace) WS="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help)
      echo "Usage: $0 --skill <skill-dir> --workspace <ws> [--yes]"
      echo "Removes the state files the skill's manifest declares as outputs."
      exit 0
      ;;
    *) shift ;;
  esac
done

[ -n "$SKILL_DIR" ] || { echo "skill-cleanup.sh: --skill required" >&2; exit 2; }
[ -n "$WS" ] || { echo "skill-cleanup.sh: --workspace required" >&2; exit 2; }

MANIFEST="$SKILL_DIR/capability-manifest.json"
[ -f "$MANIFEST" ] || { echo "skill-cleanup.sh: no capability-manifest.json in $SKILL_DIR" >&2; exit 1; }

SKILL_NAME=$(basename "$SKILL_DIR")

# Collect declared state_write outputs (and log_entry targets, which are
# also runtime state) that live under the workspace.
TARGETS=$(jq -r '[ .outputs[]? | select(.type == "state_write" or .type == "log_entry") | .target ]
  | unique[]' "$MANIFEST" 2>/dev/null || echo "")

# ── Confirmation (TTY-safe) ──────────────────────────────────────────────
if [ "$YES" -eq 0 ]; then
  if [ -t 0 ]; then
    echo "Remove $SKILL_NAME state files?"
    while IFS= read -r t; do
      [ -n "$t" ] && echo "  - $WS/$t"
    done <<< "$TARGETS"
    read -r -p "Proceed? [y/N] " ANS || ANS=""
    case "$ANS" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  else
    echo "skill-cleanup.sh: refusing without --yes (stdin is not a TTY)." >&2
    exit 1
  fi
fi

# ── Remove declared state files ───────────────────────────────────────────
REMOVED=0
SKIPPED=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$t" in
    /*) echo "  SKIP (absolute path refused): $t"; SKIPPED=$((SKIPPED+1)); continue ;;
    *..*) echo "  SKIP (path traversal refused): $t"; SKIPPED=$((SKIPPED+1)); continue ;;
  esac
  FULL="$WS/$t"
  if [ -e "$FULL" ] || [ -L "$FULL" ]; then
    rm -f "$FULL"
    echo "  removed $t"
    REMOVED=$((REMOVED+1))
  fi
done <<< "$TARGETS"

echo "✅ $SKILL_NAME: removed $REMOVED state file(s) ($SKIPPED skipped)."
exit 0
