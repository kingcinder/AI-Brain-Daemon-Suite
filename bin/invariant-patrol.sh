#!/usr/bin/env bash
# invariant-patrol.sh — wrapper for invariant-patrol.py (see its docstring).
# Read-only over the harness; writes only ~/.juno-brain/run/patrol-state.json.
exec python3 "$HOME/.juno-brain/bin/invariant-patrol.py" "$@"
