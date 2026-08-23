#!/bin/bash
# Unit: Basal-ganglia action-select gates sub-threshold candidates behind a
# no-go threshold (Mink's gating framework; Frank's BG models) — the winner
# is only RELEASED if its adjusted score crosses the threshold.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT

OPTS='[{"id":"a","label":"risky bet","score":0.3},{"id":"b","label":"safe move","score":0.8}]'

# Threshold above the best score (0.9 > 0.8) → nothing released (chosen null)
OUT=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/basal-ganglia-memory/scripts/action-select.sh" --options "$OPTS" --threshold 0.9 --epsilon 0 --no-record)
echo "$OUT" | jq -e '.chosen == null' >/dev/null
echo "$OUT" | jq -e '.method | startswith("gated")' >/dev/null
echo "$OUT" | jq -e '.losers | length == 2' >/dev/null

# Threshold below the best score (0.5) → 'b' (0.8) is released
OUT2=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/basal-ganglia-memory/scripts/action-select.sh" --options "$OPTS" --threshold 0.5 --epsilon 0 --no-record)
echo "$OUT2" | jq -e '.chosen.id == "b"' >/dev/null

# Default threshold 0 → behavior unchanged (best candidate always released)
OUT3=$(WORKSPACE="$WORKSPACE" bash "$ROOT/skills/basal-ganglia-memory/scripts/action-select.sh" --options "$OPTS" --epsilon 0 --no-record)
echo "$OUT3" | jq -e '.chosen.id == "b"' >/dev/null

echo "PASS: basal-ganglia selection-threshold gating"
