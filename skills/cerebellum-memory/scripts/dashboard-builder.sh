#!/bin/bash
# Thin wrapper — shared logic lives in core/dashboard/dashboard-builder.sh
# (de-duplicated from 15 identical per-skill copies, 2026-08-24).
# Resolve relative to the repo root so this works from any checkout path.
SUITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$SUITE_ROOT/core/dashboard/dashboard-builder.sh" "$@"
