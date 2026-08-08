#!/bin/bash
# rollback.sh — Explicit rollback: restore file backups + LKG workspace snapshot.
#
# Prefer:
#   1. File restore from memory/self-mod/backups/<proposal_id>/
#   2. git revert / git checkout if .git present (best-effort)
#   3. snapshot.sh restore --id <pre_snapshot>
#
# Usage:
#   rollback.sh --proposal-id ID [--suite-root PATH] [--reason TEXT]
#   rollback.sh --deploy-record PATH.json

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
PID=""
RECORD=""
REASON="manual"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proposal-id) PID="$2"; shift 2 ;;
    --deploy-record) RECORD="$2"; shift 2 ;;
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "$RECORD" ] && [ -f "$RECORD" ]; then
  PID=$(jq -r .proposal_id "$RECORD")
elif [ -z "$PID" ] && [ -f "$WORKSPACE/memory/self-mod/deploys/LATEST" ]; then
  PID=$(cat "$WORKSPACE/memory/self-mod/deploys/LATEST")
  RECORD="$WORKSPACE/memory/self-mod/deploys/${PID}.json"
fi

if [ -z "$RECORD" ] || [ ! -f "$RECORD" ]; then
  RECORD="$WORKSPACE/memory/self-mod/deploys/${PID}.json"
fi
[ -f "$RECORD" ] || { echo "rollback: deploy record not found for $PID" >&2; exit 1; }

PID=$(jq -r .proposal_id "$RECORD")
BACKUP=$(jq -r .backup_dir "$RECORD")
PRE_SNAP=$(jq -r .pre_snapshot "$RECORD")
SUITE_ROOT=$(jq -r '.suite_root // empty' "$RECORD")
SUITE_ROOT="${SUITE_ROOT:-$ROOT}"

LOCK_DIR="$WORKSPACE/memory/locks/self-mod-deploy"
# shellcheck source=/dev/null
source "$ROOT/core/locks/rwlock.sh"

if ! rwlock_write_acquire "$LOCK_DIR" 120 20; then
  echo '{"error":"write_lock_failed"}' >&2
  exit 1
fi
trap 'rwlock_write_release "$LOCK_DIR" || true' EXIT

restored_files=0
if [ -d "$BACKUP" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$BACKUP"/}"
    if [[ "$rel" == *.missing ]]; then
      # original was missing — remove deployed file if present
      target_rel="${rel%.missing}"
      rm -f "$SUITE_ROOT/$target_rel" 2>/dev/null || true
      continue
    fi
    dest="$SUITE_ROOT/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest"
    restored_files=$((restored_files + 1))
  done < <(find "$BACKUP" -type f ! -name '*.missing' -print0 2>/dev/null)
fi

# Best-effort git restore if repo
GIT_OK=false
if [ -d "$SUITE_ROOT/.git" ]; then
  if git -C "$SUITE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # checkout backed-up paths from HEAD if still dirty — prefer backup files already restored
    GIT_OK=true
  fi
fi

# Restore workspace LKG state from pre-deploy snapshot
SNAP_OK=false
if [ -n "$PRE_SNAP" ] && [ "$PRE_SNAP" != "null" ]; then
  if WORKSPACE="$WORKSPACE" bash "$ROOT/core/snapshot/snapshot.sh" restore --id "$PRE_SNAP" >/dev/null 2>&1; then
    SNAP_OK=true
  fi
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
python3 - "$RECORD" "$TS" "$REASON" "$restored_files" "$GIT_OK" "$SNAP_OK" <<'PY'
import json,sys
from pathlib import Path
rec=Path(sys.argv[1])
d=json.loads(rec.read_text())
d["rolled_back"]=True
d["rollback_at"]=sys.argv[2]
d["rollback_reason"]=sys.argv[3]
d["rollback_detail"]={
  "files_restored": int(sys.argv[4]),
  "git_repo": sys.argv[5]=="true",
  "snapshot_restored": sys.argv[6]=="true",
}
d.setdefault("monitor",{})["status"]="rolled_back"
rec.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
print(json.dumps(d, indent=2))
PY

# Proposal status
if [ -f "$WORKSPACE/memory/self-mod/proposals/${PID}.json" ]; then
  WORKSPACE="$WORKSPACE" bash "$SELF_DIR/proposal-store.sh" set-status --id "$PID" --status rolled_back >/dev/null || true
fi

WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" append \
  --proposal-id "$PID" \
  --content "rollback:$PID:$REASON" \
  --parent-hash "$PRE_SNAP" \
  --proposer "rollback" \
  --rollback-status rolled_back >/dev/null 2>&1 || true
