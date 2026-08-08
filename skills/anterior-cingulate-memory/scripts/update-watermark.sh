#!/usr/bin/env bash
# scripts/update-watermark.sh — Track the last processed transcript position
# for the encode-pipeline so we don't re-analyze the same exchanges.
#
# Usage:
#   ./update-watermark.sh --get         # print current watermark value
#   ./update-watermark.sh --set <value> # set watermark to value
#   ./update-watermark.sh --reset       # reset to 0

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
WM_FILE="$WORKSPACE/memory/acc-encode-watermark.txt"

mkdir -p "$WORKSPACE/memory"

ACTION="${1:-get}"
VALUE="${2:-}"

case "$ACTION" in
  --get|get)
    if [[ -f "$WM_FILE" ]]; then
      cat "$WM_FILE"
    else
      echo "0"
    fi
    ;;

  --set|set)
    if [[ -z "$VALUE" ]]; then
      echo "ERROR: provide a value with --set" >&2; exit 1
    fi
    echo "$VALUE" > "$WM_FILE"
    echo "Watermark set to: $VALUE"
    ;;

  --reset|reset)
    echo "0" > "$WM_FILE"
    echo "Watermark reset to 0"
    ;;

  *)
    echo "Usage: $0 [--get|--set <value>|--reset]" >&2
    exit 1
    ;;
esac
