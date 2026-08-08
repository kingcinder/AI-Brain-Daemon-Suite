#!/bin/bash
# semaphore.sh — Hardware-calibrated concurrency + KV cache caps (V4.0 Immutable Core).
#
# Rules:
#   - Max 1 concurrent background inference call (total contexts ≤ 2)
#   - Background tasks hard-capped at 2048 tokens KV cache
#   - Non-inference operations exempt
#
# Usage:
#   semaphore_acquire_inference [lock-dir]   # blocks/fails if slot taken
#   semaphore_release_inference [lock-dir]
#   semaphore_check_kv_cap <requested-tokens>  # 0 if ok, 1 if over cap
#   semaphore_status [lock-dir]
#
# Defaults:
#   SEM_DIR=$WORKSPACE/memory/locks/inference-semaphore
#   MAX_BACKGROUND_INFERENCE=1
#   MAX_TOTAL_CONTEXTS=2
#   KV_CACHE_TOKEN_CAP=2048

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
MAX_BACKGROUND_INFERENCE="${MAX_BACKGROUND_INFERENCE:-1}"
MAX_TOTAL_CONTEXTS="${MAX_TOTAL_CONTEXTS:-2}"
KV_CACHE_TOKEN_CAP="${KV_CACHE_TOKEN_CAP:-2048}"

_sem_dir() {
  echo "${1:-${SEM_DIR:-$WORKSPACE/memory/locks/inference-semaphore}}"
}

semaphore_acquire_inference() {
  local dir
  dir=$(_sem_dir "${1:-}")
  mkdir -p "$dir"
  local slot="$dir/bg-inference.lock"
  touch "$slot"
  exec 230>"$slot"
  if ! flock -n 230; then
    echo "semaphore: background inference slot busy (max=${MAX_BACKGROUND_INFERENCE})" >&2
    exec 230>&-
    return 1
  fi
  echo $$ > "$dir/holder.pid"
  date +%s > "$dir/holder.since"
  echo "inference" > "$dir/holder.kind"
  # Track context count (primary + this background = 2 max by policy)
  local contexts=1
  if [ -f "$dir/contexts.count" ]; then
    contexts=$(cat "$dir/contexts.count")
  fi
  contexts=$((contexts + 1))
  if [ "$contexts" -gt "$MAX_TOTAL_CONTEXTS" ]; then
    echo "semaphore: total contexts would exceed $MAX_TOTAL_CONTEXTS" >&2
    exec 230>&-
    return 1
  fi
  echo "$contexts" > "$dir/contexts.count"
  return 0
}

semaphore_release_inference() {
  local dir
  dir=$(_sem_dir "${1:-}")
  if [ -f "$dir/contexts.count" ]; then
    local contexts
    contexts=$(cat "$dir/contexts.count")
    if [ "$contexts" -gt 0 ]; then
      echo $((contexts - 1)) > "$dir/contexts.count"
    fi
  fi
  rm -f "$dir/holder.pid" "$dir/holder.since" "$dir/holder.kind" 2>/dev/null || true
  exec 230>&- 2>/dev/null || true
  return 0
}

semaphore_check_kv_cap() {
  local requested="${1:?requested tokens required}"
  if ! [[ "$requested" =~ ^[0-9]+$ ]]; then
    echo "semaphore: requested tokens must be integer" >&2
    return 2
  fi
  if [ "$requested" -gt "$KV_CACHE_TOKEN_CAP" ]; then
    echo "semaphore: requested $requested tokens exceeds KV cap $KV_CACHE_TOKEN_CAP" >&2
    return 1
  fi
  return 0
}

semaphore_status() {
  local dir
  dir=$(_sem_dir "${1:-}")
  mkdir -p "$dir"
  local busy=false
  if [ -f "$dir/holder.pid" ] && kill -0 "$(cat "$dir/holder.pid")" 2>/dev/null; then
    busy=true
  fi
  local contexts=0
  [ -f "$dir/contexts.count" ] && contexts=$(cat "$dir/contexts.count")
  jq -nc \
    --argjson busy "$busy" \
    --argjson contexts "$contexts" \
    --argjson max_inf "$MAX_BACKGROUND_INFERENCE" \
    --argjson max_ctx "$MAX_TOTAL_CONTEXTS" \
    --argjson kv_cap "$KV_CACHE_TOKEN_CAP" \
    '{
      background_inference_busy: $busy,
      contexts: $contexts,
      max_background_inference: $max_inf,
      max_total_contexts: $max_ctx,
      kv_cache_token_cap: $kv_cap
    }'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    acquire)  semaphore_acquire_inference "$@" ;;
    release)  semaphore_release_inference "$@" ;;
    check-kv) semaphore_check_kv_cap "$@" ;;
    status)   semaphore_status "$@" ;;
    *)
      echo "Usage: $0 {acquire|release|check-kv|status} ..." >&2
      exit 2
      ;;
  esac
fi
