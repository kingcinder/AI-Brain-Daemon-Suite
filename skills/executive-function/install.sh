#!/bin/bash
# install.sh — executive-function: initialize suite state for this organ.
# Created at port time (2026-11-08) per the suite's organ pattern: state
# init only — no cron, no services (the daemon's job table owns timing).
set -eu
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
mkdir -p "$WORKSPACE/memory/executive"
echo "executive-function: state initialized under $WORKSPACE/memory/executive"
