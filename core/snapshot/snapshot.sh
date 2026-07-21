#!/bin/bash
# snapshot.sh — Snapshot + divergence checking (Phase 1b / Immutable Core support).
#
# Snapshot Divergence Rule (V4.0):
#   - Goals/Inhibitions: any change → fresh snapshot + re-test
#   - Executive Load: absolute difference > 0.12 → re-test
# Write-lock should be held by caller from check until apply/reject.
# Primary loop reads last-known-good while write-locked.
#
# Usage:
#   snapshot.sh create --label NAME [--files f1,f2,...]
#   snapshot.sh restore --id ID
#   snapshot.sh latest
#   snapshot.sh divergence-check --baseline ID|--latest [--current-eload N]
#   snapshot.sh lkg-path          # path to last-known-good pointer

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SNAP_ROOT="${SNAPSHOT_ROOT:-$WORKSPACE/memory/snapshots}"
LKG_POINTER="$SNAP_ROOT/last-known-good"
DEFAULT_FILES=(
  "$WORKSPACE/memory/pfc-state.json"
  "$WORKSPACE/memory/executive-load.json"
  "$WORKSPACE/memory/decision-queue.json"
)

hash_file() {
  if [ -f "$1" ]; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "missing"
  fi
}

goals_hash() {
  local f="$WORKSPACE/memory/pfc-state.json"
  if [ -f "$f" ]; then
    jq -c '[.goals[]? | select(.status=="active")]' "$f" 2>/dev/null | sha256sum | awk '{print $1}'
  else
    echo "missing"
  fi
}

inhibitions_hash() {
  local f="$WORKSPACE/memory/pfc-state.json"
  if [ -f "$f" ]; then
    jq -c '.inhibitions // []' "$f" 2>/dev/null | sha256sum | awk '{print $1}'
  else
    echo "missing"
  fi
}

current_eload() {
  local f="$WORKSPACE/memory/executive-load.json"
  if [ -f "$f" ]; then
    jq -r '.E // 0' "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

cmd_create() {
  local label="auto"
  local files_csv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --files) files_csv="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local id ts dir
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  id="${ts}-${label}-$$"
  dir="$SNAP_ROOT/$id"
  mkdir -p "$dir/files"

  local -a files=()
  if [ -n "$files_csv" ]; then
    IFS=',' read -ra files <<< "$files_csv"
  else
    files=("${DEFAULT_FILES[@]}")
  fi

  local file_meta="[]"
  local f base
  for f in "${files[@]}"; do
    [ -z "$f" ] && continue
    base=$(basename "$f")
    if [ -f "$f" ]; then
      cp -a "$f" "$dir/files/$base"
      file_meta=$(echo "$file_meta" | jq -c --arg p "$f" --arg b "$base" --arg h "$(hash_file "$f")" \
        '. + [{path:$p, stored_as:$b, sha256:$h}]')
    else
      file_meta=$(echo "$file_meta" | jq -c --arg p "$f" --arg b "$base" \
        '. + [{path:$p, stored_as:$b, sha256:"missing"}]')
    fi
  done

  local meta
  meta=$(jq -nc \
    --arg id "$id" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson files "$file_meta" \
    --argjson eload "$(current_eload)" \
    --arg gh "$(goals_hash)" \
    --arg ih "$(inhibitions_hash)" \
    '{
      snapshot_id: $id,
      created_at: $ts,
      files: $files,
      executive_load: $eload,
      goals_hash: $gh,
      inhibitions_hash: $ih
    }')
  echo "$meta" > "$dir/meta.json"
  mkdir -p "$SNAP_ROOT"
  echo "$id" > "$LKG_POINTER"
  echo "$meta"
}

cmd_restore() {
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$id" ]; then
    echo "restore requires --id" >&2
    exit 2
  fi
  local dir="$SNAP_ROOT/$id"
  if [ ! -f "$dir/meta.json" ]; then
    echo "snapshot not found: $id" >&2
    exit 1
  fi
  jq -c '.files[]' "$dir/meta.json" | while read -r entry; do
    local path stored
    path=$(echo "$entry" | jq -r .path)
    stored=$(echo "$entry" | jq -r .stored_as)
    if [ -f "$dir/files/$stored" ]; then
      mkdir -p "$(dirname "$path")"
      cp -a "$dir/files/$stored" "$path"
    fi
  done
  echo "restored snapshot $id"
}

cmd_latest() {
  if [ -f "$LKG_POINTER" ]; then
    local id
    id=$(cat "$LKG_POINTER")
    if [ -f "$SNAP_ROOT/$id/meta.json" ]; then
      cat "$SNAP_ROOT/$id/meta.json"
      return 0
    fi
  fi
  echo '{"error":"no last-known-good snapshot"}' >&2
  return 1
}

cmd_divergence() {
  local baseline="" current_e=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline) baseline="$2"; shift 2 ;;
      --latest) baseline=$(cat "$LKG_POINTER" 2>/dev/null || true); shift ;;
      --current-eload) current_e="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$baseline" ] || [ ! -f "$SNAP_ROOT/$baseline/meta.json" ]; then
    echo "divergence-check: missing baseline" >&2
    exit 2
  fi
  local meta gh ih base_e
  meta=$(cat "$SNAP_ROOT/$baseline/meta.json")
  gh=$(echo "$meta" | jq -r .goals_hash)
  ih=$(echo "$meta" | jq -r .inhibitions_hash)
  base_e=$(echo "$meta" | jq -r .executive_load)
  [ -n "$current_e" ] || current_e=$(current_eload)

  local cur_gh cur_ih
  cur_gh=$(goals_hash)
  cur_ih=$(inhibitions_hash)

  local goals_changed=false inhib_changed=false eload_divergent=false retest=false
  [ "$cur_gh" != "$gh" ] && goals_changed=true
  [ "$cur_ih" != "$ih" ] && inhib_changed=true

  local delta
  delta=$(python3 -c "print(abs(float('$current_e') - float('$base_e')))")
  python3 -c "import sys; sys.exit(0 if abs(float('$current_e')-float('$base_e')) > 0.12 else 1)" && eload_divergent=true || true

  if $goals_changed || $inhib_changed || $eload_divergent; then
    retest=true
  fi

  jq -nc \
    --arg baseline "$baseline" \
    --argjson goals_changed "$goals_changed" \
    --argjson inhib_changed "$inhib_changed" \
    --argjson eload_divergent "$eload_divergent" \
    --argjson retest "$retest" \
    --argjson base_e "$base_e" \
    --argjson cur_e "$current_e" \
    --argjson delta "$delta" \
    '{
      baseline: $baseline,
      goals_changed: $goals_changed,
      inhibitions_changed: $inhib_changed,
      executive_load_divergent: $eload_divergent,
      executive_load_delta: $delta,
      baseline_executive_load: $base_e,
      current_executive_load: $cur_e,
      retest_required: $retest,
      rule: {
        goals_inhibitions: "any change -> fresh snapshot + re-test",
        executive_load: "abs diff > 0.12 -> re-test"
      }
    }'
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  latest) shift; cmd_latest "$@" ;;
  divergence-check) shift; cmd_divergence "$@" ;;
  lkg-path) echo "$LKG_POINTER" ;;
  *)
    echo "Usage: $0 {create|restore|latest|divergence-check|lkg-path} ..." >&2
    exit 2
    ;;
esac
