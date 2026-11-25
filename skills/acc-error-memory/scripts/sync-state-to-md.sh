#!/usr/bin/env bash
# sync-state-to-md.sh — Deprecated wrapper; delegates to sync-state.sh
# sync-state.sh is the canonical implementation.
# This file is kept for backwards compatibility.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/sync-state.sh" "$@"
