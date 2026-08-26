#!/bin/bash
# deploy-proposal.sh — Deploy an *accepted* proposal under RWLock + divergence re-check.
#
# Steps:
#   1. Re-run check-target
#   2. Create baseline snapshot (state files)
#   3. Backup target files under memory/self-mod/backups/
#   4. Acquire write lock
#   5. Divergence check; if retest required, re-evaluate quickly (check-target only + optional)
#   6. apply-patch to live suite root
#   7. Point LKG; provenance; release lock
#   8. Write deploy record for monitor
#
# Usage:
#   deploy-proposal.sh --proposal PATH.json [--suite-root PATH] [--skip-eval]
# Env: WORKSPACE

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
PROPOSAL=""
SKIP_EVAL=0
LOCK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proposal) PROPOSAL="$2"; shift 2 ;;
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --skip-eval) SKIP_EVAL=1; shift ;;
    *) shift ;;
  esac
done

[ -f "$PROPOSAL" ] || { echo "deploy requires --proposal" >&2; exit 2; }
PID=$(jq -r .proposal_id "$PROPOSAL")
LOCK_DIR="${LOCK_DIR:-$WORKSPACE/memory/locks/self-mod-deploy}"
# shellcheck source=/dev/null
source "$ROOT/core/locks/rwlock.sh"

# Target guard — mktemp file (never a predictable /tmp/name.$$ path)
DEPLOY_CHECK=$(mktemp "${TMPDIR:-/tmp}/aibrain-deploy-check.XXXXXX")
bash "$SELF_DIR/check-target.sh" --suite-root "$SUITE_ROOT" --proposal "$PROPOSAL" >"$DEPLOY_CHECK" \
  || { echo "deploy: target check failed"; cat "$DEPLOY_CHECK"; rm -f "$DEPLOY_CHECK"; exit 1; }
rm -f "$DEPLOY_CHECK"

# Optional re-eval unless skip
if [ "$SKIP_EVAL" -eq 0 ]; then
  EVAL=$(bash "$SELF_DIR/evaluate-proposal.sh" --proposal "$PROPOSAL" --suite-root "$SUITE_ROOT" --workspace "$WORKSPACE")
  ACC=$(echo "$EVAL" | jq -r .accepted)
  if [ "$ACC" != "true" ]; then
    echo "$EVAL" | jq -c '{proposal_id, accepted:false, stage:"pre-deploy-eval", reason, utility}'
    exit 1
  fi
fi

# Snapshot workspace state
SNAP=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/snapshot/snapshot.sh" create --label "pre-deploy-$PID")
SNAP_ID=$(echo "$SNAP" | jq -r .snapshot_id)

# Backup files
BACKUP_DIR="$WORKSPACE/memory/self-mod/backups/$PID"
mkdir -p "$BACKUP_DIR"
while IFS= read -r t; do
  [ -z "$t" ] && continue
  src="$SUITE_ROOT/$t"
  if [ -f "$src" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$t")"
    cp -a "$src" "$BACKUP_DIR/$t"
  else
    mkdir -p "$BACKUP_DIR/$(dirname "$t")"
    echo "__MISSING__" > "$BACKUP_DIR/$t.missing"
  fi
done < <(jq -r '(.target_paths // .targets // [])[]?' "$PROPOSAL")

# Write lock held until apply/reject
if ! rwlock_write_acquire "$LOCK_DIR" 120 20; then
  echo '{"error":"write_lock_failed"}' >&2
  exit 1
fi
release_lock() { rwlock_write_release "$LOCK_DIR" || true; }
trap release_lock EXIT

# Divergence check
DIV=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/snapshot/snapshot.sh" divergence-check --baseline "$SNAP_ID" || true)
RETEST=$(echo "$DIV" | jq -r '.retest_required // false')
if [ "$RETEST" = "true" ]; then
  # Fresh snapshot + re-check targets only (state moved under us)
  SNAP=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/snapshot/snapshot.sh" create --label "retest-deploy-$PID")
  SNAP_ID=$(echo "$SNAP" | jq -r .snapshot_id)
  bash "$SELF_DIR/check-target.sh" --suite-root "$SUITE_ROOT" --proposal "$PROPOSAL" >/dev/null
fi

rwlock_write_heartbeat "$LOCK_DIR"

# Apply to live suite
APPLY=$(bash "$SELF_DIR/apply-patch.sh" --suite-root "$SUITE_ROOT" --proposal "$PROPOSAL")
OK=$(echo "$APPLY" | jq -r .ok)
if [ "$OK" != "true" ]; then
  echo "$APPLY" | jq -c --arg pid "$PID" '{proposal_id:$pid, deployed:false, apply:.}'
  exit 1
fi

# Post-deploy LKG snapshot
POST=$(WORKSPACE="$WORKSPACE" bash "$ROOT/core/snapshot/snapshot.sh" create --label "post-deploy-$PID")
POST_ID=$(echo "$POST" | jq -r .snapshot_id)

# Deploy record for monitor
mkdir -p "$WORKSPACE/memory/self-mod/deploys"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RECORD=$(jq -nc \
  --arg pid "$PID" \
  --arg ts "$TS" \
  --arg snap "$SNAP_ID" \
  --arg post "$POST_ID" \
  --arg backup "$BACKUP_DIR" \
  --arg suite "$SUITE_ROOT" \
  --argjson apply "$APPLY" \
  --argjson div "$DIV" \
  '{
    proposal_id: $pid,
    deployed_at: $ts,
    pre_snapshot: $snap,
    post_snapshot: $post,
    backup_dir: $backup,
    suite_root: $suite,
    apply: $apply,
    divergence_at_deploy: $div,
    monitor: {status: "active", breaches: []},
    rolled_back: false
  }')
echo "$RECORD" > "$WORKSPACE/memory/self-mod/deploys/${PID}.json"
echo "$PID" > "$WORKSPACE/memory/self-mod/deploys/LATEST"

# Update proposal status
if [ -f "$WORKSPACE/memory/self-mod/proposals/${PID}.json" ]; then
  WORKSPACE="$WORKSPACE" bash "$SELF_DIR/proposal-store.sh" set-status --id "$PID" --status deployed >/dev/null || true
fi

# Provenance
WORKSPACE="$WORKSPACE" bash "$ROOT/core/provenance/log-provenance.sh" append \
  --proposal-id "$PID" \
  --content "deployed:$PID:$POST_ID" \
  --parent-hash "$SNAP_ID" \
  --proposer "deploy-proposal" \
  --sandbox-score 1 \
  --utility-score "$(jq -r '.scores.post_utility // 0' "$PROPOSAL" 2>/dev/null || echo 0)" \
  --rollback-status none >/dev/null 2>&1 || true

echo "$RECORD" | jq .
# lock released by trap
