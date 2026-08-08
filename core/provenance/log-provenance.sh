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
#   log-provenance.sh event --event NAME [--actor NAME] [--detail JSON]
#     Generic audit event (not a patch): appends to events.jsonl with
#     {ts, event, actor, detail}. Used for non-patch decisions that must be
#     auditable — e.g. every autonomy-mode decision (kernel --autonomy
#     computation, run-pipeline deploy/defer gate outcomes).
#
#   log-provenance.sh events [--filter SUBSTRING] [--limit N]
#     Compact audit table over events.jsonl (the mirror of `show`, which
#     reads the patch DAG): TS | EVENT | ACTOR | DETAIL. --filter matches
#     the event name case-insensitively — `events --filter autonomy` gives
#     the steward every autonomy-mode decision (mode.decided + gate
#     deferred/blocked/allowed) in one terminal command. --limit caps the
#     newest rows shown (default 25).
#
#   log-provenance.sh show [--limit N]
#   log-provenance.sh hash <path-or-string>
#
# Log files:
#   $WORKSPACE/memory/provenance/patches.jsonl (patch DAG, append-only JSONL)
#   $WORKSPACE/memory/provenance/events.jsonl (generic audit events)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
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

cmd_event() {
  # Generic audit event (not a patch): appends {ts, event, actor, detail} to
  # events.jsonl. Never fails the caller — a malformed --detail degrades to
  # {} rather than aborting (the caller's decision is already made; the
  # audit trail must not be able to break it).
  local event="" actor="unknown" detail="{}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --event) event="$2"; shift 2 ;;
      --actor) actor="$2"; shift 2 ;;
      --detail) detail="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$event" ]; then
    echo "Usage: event requires --event" >&2
    exit 2
  fi
  mkdir -p "$PROV_DIR"
  local ts entry tmp
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Build JSON entry; --detail must already be a JSON object string. If it is
  # malformed, fall back to {} so the audit line is never lost to a typo.
  entry=$(jq -nc --arg ts "$ts" --arg ev "$event" --arg ac "$actor" --argjson dt "$detail" \
    '{ts:$ts, event:$ev, actor:$ac, detail:$dt}' 2>/dev/null || \
    jq -nc --arg ts "$ts" --arg ev "$event" --arg ac "$actor" \
    '{ts:$ts, event:$ev, actor:$ac, detail:{}}')
  tmp=$(mktemp)
  printf '%s\n' "$entry" > "$tmp"
  cat "$tmp" >> "$PROV_DIR/events.jsonl"
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

cmd_events() {
  # Compact audit table over events.jsonl (generic audit events written by
  # `log-provenance.sh event`). Mirrors `show` — which renders the patch
  # DAG — but for the event trail, as a human-readable table instead of raw
  # JSON: TS | EVENT | ACTOR | DETAIL. The steward audits every autonomy-mode
  # decision from the terminal with `events --filter autonomy` (mode.decided
  # computations + deferred / deploy_blocked / deploy_allowed gate outcomes).
  local filter="" limit=25
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filter) filter="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
  done
  local ev_file="$PROV_DIR/events.jsonl"
  if [ ! -f "$ev_file" ]; then
    echo "No events logged yet ($ev_file)."
    return 0
  fi
  local filter_lc
  filter_lc=$(printf '%s' "$filter" | tr 'A-Z' 'a-z')
  printf '%-22s  %-30s  %-18s  %s\n' "TS" "EVENT" "ACTOR" "DETAIL"
  printf '%-22s  %-30s  %-18s  %s\n' "---" "-----" "-----" "------"
  # NOTE: the select guard needs explicit parens — in jq, `and` binds tighter
  # than `|`, so without them `.event` would be re-indexed on the piped string
  # ("Cannot index string with string \"event\"").
  if ! jq -r -s --arg f "$filter_lc" --argjson lim "$limit" '
    (if $f == "" then . else [.[] | select((.event | type == "string") and ((.event | ascii_downcase) | contains($f)))] end)
    | .[-$lim:]
    | .[]
    | [.ts // "-", .event // "-", .actor // "-",
       ((.detail // {}) | if type == "object" then
          (if .transition then "\(.mode) · \(.transition)"
           elif .reason then "\(.autonomy_mode) + \(.review_mode) · \(.reason)"
           else (tostring | .[0:80]) end)
        else (tostring | .[0:80]) end)]
    | @tsv
  ' "$ev_file" | awk -F'\t' '{ printf "%-22s  %-30s  %-18s  %s\n", $1, $2, $3, $4 }'; then
    # Corrupt/truncated events.jsonl (or a non-numeric --limit): degrade to a
    # readable message instead of a raw jq error under set -euo pipefail.
    echo "(events.jsonl unreadable or malformed — skipping table)" >&2
    return 1
  fi
}

case "${1:-}" in
  append) shift; cmd_append "$@" ;;
  event)  shift; cmd_event "$@" ;;
  events) shift; cmd_events "$@" ;;
  show)   shift; cmd_show "$@" ;;
  hash)   shift; cmd_hash "$@" ;;
  *)
    echo "Usage: $0 {append|event|events|show|hash} ..." >&2
    exit 2
    ;;
esac
