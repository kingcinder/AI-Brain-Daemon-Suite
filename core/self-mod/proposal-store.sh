#!/bin/bash
# proposal-store.sh — Append / list / get self-mod proposals (Phase 3).
#
# Store: $WORKSPACE/memory/self-mod/proposals/<id>.json
# Index: $WORKSPACE/memory/self-mod/proposals/index.jsonl
#
# Usage:
#   proposal-store.sh add --file PATH.json | --stdin
#   proposal-store.sh list [--status queued|ranked|accepted|rejected|deployed|rolled_back]
#   proposal-store.sh get --id ID
#   proposal-store.sh set-status --id ID --status STATUS

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STORE="$WORKSPACE/memory/self-mod/proposals"
INDEX="$STORE/index.jsonl"

mkdir -p "$STORE"

cmd_add() {
  local file="" use_stdin=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) file="$2"; shift 2 ;;
      --stdin) use_stdin=1; shift ;;
      *) shift ;;
    esac
  done
  local raw
  if [ "$use_stdin" -eq 1 ]; then
    raw=$(cat)
  elif [ -n "$file" ]; then
    raw=$(cat "$file")
  else
    echo "add requires --file or --stdin" >&2
    exit 2
  fi

  # Write raw JSON to a temp file — do not use a heredoc for the interpreter
  # stdin (that would steal the proposal body from the pipe).
  local raw_file
  raw_file=$(mktemp)
  printf '%s' "$raw" > "$raw_file"
  python3 - "$STORE" "$INDEX" "$raw_file" <<'PY'
import json, sys, hashlib
from pathlib import Path
from datetime import datetime, timezone

store = Path(sys.argv[1])
index = Path(sys.argv[2])
prop = json.loads(Path(sys.argv[3]).read_text())
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if not prop.get("proposal_id"):
    blob = json.dumps(prop, sort_keys=True)
    prop["proposal_id"] = "prop_" + hashlib.sha256(blob.encode()).hexdigest()[:16]
prop.setdefault("status", "queued")
prop.setdefault("created_at", now)
prop.setdefault("updated_at", now)
pid = prop["proposal_id"]
path = store / f"{pid}.json"
path.write_text(json.dumps(prop, indent=2, sort_keys=True) + "\n")
with open(index, "a") as f:
    f.write(json.dumps({"proposal_id": pid, "status": prop["status"], "ts": now}, sort_keys=True) + "\n")
print(json.dumps({"stored": str(path), "proposal_id": pid, "status": prop["status"]}, indent=2))
PY
  rm -f "$raw_file"
}

cmd_list() {
  local status=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) status="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  python3 - "$STORE" "$status" <<'PY'
import json, sys
from pathlib import Path
store = Path(sys.argv[1])
want = sys.argv[2] or ""
rows = []
for p in sorted(store.glob("*.json")):
    if p.name == "index.jsonl":
        continue
    try:
        d = json.loads(p.read_text())
    except Exception:
        continue
    if want and d.get("status") != want:
        continue
    rows.append({
        "proposal_id": d.get("proposal_id"),
        "status": d.get("status"),
        "module": d.get("module"),
        "target_paths": d.get("target_paths") or d.get("targets"),
        "pre_utility": (d.get("scores") or {}).get("pre_utility"),
    })
print(json.dumps(rows, indent=2))
PY
}

cmd_get() {
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$id" ] || { echo "get requires --id" >&2; exit 2; }
  local f="$STORE/$id.json"
  [ -f "$f" ] || { echo "not found: $id" >&2; exit 1; }
  cat "$f"
}

cmd_set_status() {
  local id="" status=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$id" ] && [ -n "$status" ] || { echo "set-status requires --id and --status" >&2; exit 2; }
  python3 - "$STORE/$id.json" "$status" "$INDEX" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone
path = Path(sys.argv[1])
status = sys.argv[2]
index = Path(sys.argv[3])
d = json.loads(path.read_text())
d["status"] = status
d["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
path.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
with open(index, "a") as f:
    f.write(json.dumps({"proposal_id": d["proposal_id"], "status": status, "ts": d["updated_at"]}, sort_keys=True) + "\n")
print(json.dumps({"proposal_id": d["proposal_id"], "status": status}))
PY
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  list) shift; cmd_list "$@" ;;
  get) shift; cmd_get "$@" ;;
  set-status) shift; cmd_set_status "$@" ;;
  *)
    echo "Usage: $0 {add|list|get|set-status} ..." >&2
    exit 2
    ;;
esac
