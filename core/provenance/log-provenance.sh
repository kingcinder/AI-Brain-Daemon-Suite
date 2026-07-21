#!/bin/bash
# log-provenance.sh — Lightweight per-patch provenance logger (Phase 1a).
#
# Per patch: proposal ID, content hash (SHA-256), parent hash, timestamp,
# proposer/reviewer, sandbox score, utility score, rollback status.
# Full cryptographic DAG deferred to Phase 4.
#
# Usage:
#   log-provenance.sh append \
#     --proposal-id ID --content PATH_OR_STRING --parent-hash HASH \
#     [--proposer NAME] [--reviewer NAME] \
#     [--sandbox-score N] [--utility-score N] \
#     [--rollback-status none|pending|rolled_back|accepted]
#
#   log-provenance.sh show [--limit N]
#   log-provenance.sh hash <path-or-string>
#
# Log file: $WORKSPACE/memory/provenance/patches.jsonl (append-only JSONL)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
PROV_DIR="${PROVENANCE_DIR:-$WORKSPACE/memory/provenance}"
PROV_LOG="$PROV_DIR/patches.jsonl"

sha256_of() {
  local input="$1"
  if [ -f "$input" ]; then
    sha256sum "$input" | awk '{print $1}'
  else
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  fi
}

cmd_hash() {
  sha256_of "${1:?content or path required}"
}

cmd_append() {
  local proposal_id="" content="" parent_hash="" proposer="unknown" reviewer=""
  local sandbox_score="null" utility_score="null" rollback_status="none"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proposal-id) proposal_id="$2"; shift 2 ;;
      --content) content="$2"; shift 2 ;;
      --parent-hash) parent_hash="$2"; shift 2 ;;
      --proposer) proposer="$2"; shift 2 ;;
      --reviewer) reviewer="$2"; shift 2 ;;
      --sandbox-score) sandbox_score="$2"; shift 2 ;;
      --utility-score) utility_score="$2"; shift 2 ;;
      --rollback-status) rollback_status="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  if [ -z "$proposal_id" ] || [ -z "$content" ]; then
    echo "Usage: append requires --proposal-id and --content" >&2
    exit 2
  fi
  parent_hash="${parent_hash:-null}"

  mkdir -p "$PROV_DIR"
  local content_hash ts
  content_hash=$(sha256_of "$content")
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build JSON entry (jq ensures valid escaping)
  local entry
  entry=$(jq -nc \
    --arg pid "$proposal_id" \
    --arg ch "$content_hash" \
    --arg ph "$parent_hash" \
    --arg ts "$ts" \
    --arg pr "$proposer" \
    --arg rv "$reviewer" \
    --argjson ss "$( [ "$sandbox_score" = "null" ] && echo null || echo "$sandbox_score" )" \
    --argjson us "$( [ "$utility_score" = "null" ] && echo null || echo "$utility_score" )" \
    --arg rs "$rollback_status" \
    '{
      proposal_id: $pid,
      content_hash: $ch,
      parent_hash: (if $ph == "null" or $ph == "" then null else $ph end),
      timestamp: $ts,
      proposer: $pr,
      reviewer: (if $rv == "" then null else $rv end),
      sandbox_score: $ss,
      utility_score: $us,
      rollback_status: $rs
    }')

  # Append atomically-ish: write line then fsync via temp+cat for crash safety
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$entry" > "$tmp"
  cat "$tmp" >> "$PROV_LOG"
  rm -f "$tmp"
  echo "$entry"
}

cmd_show() {
  local limit=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ ! -f "$PROV_LOG" ]; then
    echo "[]"
    return 0
  fi
  tail -n "$limit" "$PROV_LOG" | jq -s '.'
}

case "${1:-}" in
  append) shift; cmd_append "$@" ;;
  show)   shift; cmd_show "$@" ;;
  hash)   shift; cmd_hash "$@" ;;
  *)
    echo "Usage: $0 {append|show|hash} ..." >&2
    exit 2
    ;;
esac
