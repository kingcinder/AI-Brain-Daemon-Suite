#!/bin/bash
# Daemon entrypoint for Open Item 5: Hermes session → suite transcript bridge.
# Resolves core/transcripts/export-transcripts.sh either from the installed
# WORKSPACE (install.sh deploys core/ next to skills/) or from the suite tree
# (dev). Same convention as self-mod-runner/scripts/monitor-tick.sh and
# executive-function/scripts/run-cycle.sh.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$WORKSPACE/core/transcripts/export-transcripts.sh" ]; then
    exec bash "$WORKSPACE/core/transcripts/export-transcripts.sh" --workspace "$WORKSPACE"
elif [ -x "$SCRIPT_DIR/../../../core/transcripts/export-transcripts.sh" ]; then
    exec bash "$SCRIPT_DIR/../../../core/transcripts/export-transcripts.sh" --workspace "$WORKSPACE"
else
    echo "export-transcripts: core/transcripts/export-transcripts.sh not found" >&2
    echo "  checked: $WORKSPACE/core/transcripts/ and suite-relative path" >&2
    exit 1
fi
