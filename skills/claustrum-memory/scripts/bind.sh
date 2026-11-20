#!/bin/bash
# Claustrum binding pass — the organ's pipeline.
set -e
WORKSPACE="${WORKSPACE:-$HOME/.juno-brain/workspace}"
export WORKSPACE
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/bind.py"
WORKSPACE="$WORKSPACE" "$SCRIPT_DIR/sync-state.sh" 2>/dev/null || true
