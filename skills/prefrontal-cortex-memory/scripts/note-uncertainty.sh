#!/bin/bash
# note-uncertainty.sh — PFC consumer for insula interoceptive_discrepancy signals.
#
# The insula publishes interoceptive_discrepancy when its composite prediction
# error is notable (Craig's predictive-coding model; Critchley's extension to
# decision confidence). This consumer records that uncertainty as a PFC-side
# confidence input so the next decide.sh run dampens decision scores — the
# body's "something's off" signal lowers executive confidence.
#
# Usage: note-uncertainty.sh --value <0-1>
# Dispatched by route-signals.sh from insula-memory|interoceptive_discrepancy.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/pfc-uncertainty.json"

VALUE="0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --value) VALUE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Clamp to [0,1]
if [[ "$VALUE" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    VALUE=$(awk -v v="$VALUE" 'BEGIN { if (v>1) v=1; if (v<0) v=0; print v }')
else
    VALUE="0.0"
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "$STATE_FILE")"

# Serialize read-modify-write (concurrent note-uncertainty / decide runs).
exec 200>"$STATE_FILE.lock"
flock 200

tmp="$STATE_FILE.tmp.$$"
jq -n --argjson discrepancy "$VALUE" --arg now "$NOW" \
  '{interoceptiveDiscrepancy: $discrepancy, lastUpdated: $now}' > "$tmp" && mv "$tmp" "$STATE_FILE"

echo "🧭 PFC uncertainty noted: interoceptive discrepancy $VALUE — decision scores will be dampened."
