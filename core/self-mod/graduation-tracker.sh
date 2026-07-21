#!/bin/bash
# graduation-tracker.sh — Review-frequency graduation (v3.9 / v4.0).
#
# Spec (distinct from per-proposal utility acceptance in evaluate-proposal.sh):
#   A rolling streak of consecutive *clean* proposals. After CLEAN_STREAK_TARGET
#   (default 20) consecutive clean outcomes, review-frequency may be relaxed.
#   Any sandbox failure, checklist failure, or automated test failure resets
#   the streak to zero.
#
# This module only tracks the streak. It does NOT score utility and does NOT
# accept/reject a proposal on U-vs-baseline (that is evaluate-proposal.sh).
#
# Persisted state (survives daemon restart):
#   $WORKSPACE/memory/self-mod/graduation-streak.json
#
# Usage:
#   graduation-tracker.sh status
#   graduation-tracker.sh record-clean --proposal-id ID [--note TEXT]
#   graduation-tracker.sh record-failure --proposal-id ID --reason REASON
#   graduation-tracker.sh review-frequency   # prints JSON: {mode, streak, target, ...}
#   graduation-tracker.sh reset              # force streak to 0 (manual)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
STATE_DIR="$WORKSPACE/memory/self-mod"
STATE_FILE="$STATE_DIR/graduation-streak.json"
CLEAN_STREAK_TARGET="${CLEAN_STREAK_TARGET:-20}"

mkdir -p "$STATE_DIR"

_init_state() {
  if [ ! -f "$STATE_FILE" ]; then
    jq -nc \
      --argjson target "$CLEAN_STREAK_TARGET" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{
        clean_streak: 0,
        clean_streak_target: $target,
        last_event: "init",
        last_proposal_id: null,
        last_reason: null,
        last_updated: $ts,
        review_mode: "full_review",
        history: []
      }' > "$STATE_FILE"
  fi
}

_load() {
  _init_state
  cat "$STATE_FILE"
}

_save_from_stdin() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

cmd_status() {
  _load | jq .
}

cmd_review_frequency() {
  _load | python3 -c '
import json,sys
d=json.load(sys.stdin)
streak=int(d.get("clean_streak") or 0)
target=int(d.get("clean_streak_target") or 20)
graduated = streak >= target
mode = "relaxed_review" if graduated else "full_review"
out={
  "review_mode": mode,
  "graduated": graduated,
  "clean_streak": streak,
  "clean_streak_target": target,
  "remaining_to_graduate": max(0, target - streak),
  "source_file": "'"$STATE_FILE"'",
  "note": "Relaxed review only after 20 consecutive clean proposals; any failure resets to 0.",
}
print(json.dumps(out, indent=2))
'
}

cmd_record_clean() {
  local pid="" note="clean"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proposal-id) pid="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _load | python3 -c '
import json,sys
from datetime import datetime, timezone
d=json.load(sys.stdin)
pid=sys.argv[1] or None
note=sys.argv[2]
target=int(d.get("clean_streak_target") or 20)
streak=int(d.get("clean_streak") or 0) + 1
d["clean_streak"]=streak
d["last_event"]="clean"
d["last_proposal_id"]=pid
d["last_reason"]=note
d["last_updated"]=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
d["review_mode"]="relaxed_review" if streak >= target else "full_review"
hist=d.get("history") or []
hist.append({"event":"clean","proposal_id":pid,"note":note,"streak_after":streak,"ts":d["last_updated"]})
d["history"]=hist[-50:]
print(json.dumps(d, indent=2, sort_keys=True))
' "$pid" "$note" | _save_from_stdin
  cmd_review_frequency
}

cmd_record_failure() {
  local pid="" reason="failure"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proposal-id) pid="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _load | python3 -c '
import json,sys
from datetime import datetime, timezone
d=json.load(sys.stdin)
pid=sys.argv[1] or None
reason=sys.argv[2]
prev=int(d.get("clean_streak") or 0)
d["clean_streak"]=0
d["last_event"]="failure_reset"
d["last_proposal_id"]=pid
d["last_reason"]=reason
d["last_updated"]=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
d["review_mode"]="full_review"
hist=d.get("history") or []
hist.append({"event":"failure_reset","proposal_id":pid,"reason":reason,"streak_before":prev,"streak_after":0,"ts":d["last_updated"]})
d["history"]=hist[-50:]
print(json.dumps(d, indent=2, sort_keys=True))
' "$pid" "$reason" | _save_from_stdin
  cmd_review_frequency
}

cmd_reset() {
  cmd_record_failure --proposal-id "manual" --reason "manual_reset" >/dev/null
  cmd_status
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  review-frequency) shift; cmd_review_frequency "$@" ;;
  record-clean) shift; cmd_record_clean "$@" ;;
  record-failure) shift; cmd_record_failure "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  *)
    echo "Usage: $0 {status|review-frequency|record-clean|record-failure|reset} ..." >&2
    exit 2
    ;;
esac
