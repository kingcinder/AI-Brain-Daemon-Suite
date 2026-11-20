#!/bin/bash
# install.sh — self-mod-runner: initialize suite state for this organ.
# Created at port time (2026-11-08) per the suite's organ pattern: state
# init only — no cron, no services (the daemon's job table owns timing).
set -eu
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
mkdir -p "$WORKSPACE/memory/self-mod/deploys"
echo "self-mod-runner: state initialized under $WORKSPACE/memory/self-mod/deploys"
