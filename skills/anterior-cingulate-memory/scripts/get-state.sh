#!/usr/bin/env bash
# scripts/get-state.sh — Read raw conflict-state.json

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: conflict-state.json not found. Run ./install.sh first." >&2
  exit 1
fi

cat "$STATE_FILE"
