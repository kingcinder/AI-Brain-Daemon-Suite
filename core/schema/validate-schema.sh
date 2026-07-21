#!/bin/bash
# validate-schema.sh — Phase 1a schema versioning skeleton validator.
#
# Usage:
#   validate-schema.sh <document-type> <json-file>
#   validate-schema.sh --list
#   validate-schema.sh --check-registry
#
# Exit codes:
#   0 valid
#   1 validation failure
#   2 usage / missing deps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="${SCHEMA_REGISTRY:-$SCRIPT_DIR/schema-registry.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq required" >&2
  exit 2
fi

if [ ! -f "$REGISTRY" ]; then
  echo "FATAL: registry not found: $REGISTRY" >&2
  exit 2
fi

list_types() {
  jq -r '.document_types | keys[]' "$REGISTRY"
}

check_registry() {
  jq -e '
    .schema == 1
    and (.version | type == "string")
    and (.document_types | type == "object")
    and (.immutable_core_modules | type == "array")
  ' "$REGISTRY" >/dev/null
  echo "PASS: schema-registry.json structure ok (v$(jq -r .version "$REGISTRY"))"
}

validate_doc() {
  local dtype="$1" file="$2"
  if [ ! -f "$file" ]; then
    echo "FAIL: file not found: $file" >&2
    return 1
  fi
  if ! jq -e --arg t "$dtype" '.document_types[$t]' "$REGISTRY" >/dev/null 2>&1; then
    echo "FAIL: unknown document type: $dtype" >&2
    return 1
  fi

  local required
  required=$(jq -c --arg t "$dtype" '.document_types[$t].required_fields' "$REGISTRY")

  # Every required field must exist at top level
  local field missing=0
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    if ! jq -e --arg f "$field" 'has($f)' "$file" >/dev/null 2>&1; then
      echo "FAIL: missing required field '$field' in $file" >&2
      missing=1
    fi
  done < <(echo "$required" | jq -r '.[]')

  if [ "$missing" -ne 0 ]; then
    return 1
  fi

  # If document carries schema_version / version, ensure it is >= min_compatible
  local min_compat doc_ver
  min_compat=$(jq -r --arg t "$dtype" '.document_types[$t].min_compatible' "$REGISTRY")
  doc_ver=$(jq -r '.schema_version // .version // empty' "$file")
  if [ -n "$doc_ver" ] && [ -n "$min_compat" ]; then
    # Simple major.minor compare via sort -V
    local lowest
    lowest=$(printf '%s\n%s\n' "$min_compat" "$doc_ver" | sort -V | head -1)
    if [ "$lowest" != "$min_compat" ]; then
      echo "FAIL: $file version $doc_ver < min_compatible $min_compat" >&2
      return 1
    fi
  fi

  echo "PASS: $dtype validates against registry ($file)"
  return 0
}

case "${1:-}" in
  --list)
    list_types
    ;;
  --check-registry)
    check_registry
    ;;
  "")
    echo "Usage: $0 <document-type> <json-file> | --list | --check-registry" >&2
    exit 2
    ;;
  *)
    if [ "${2:-}" = "" ]; then
      echo "Usage: $0 <document-type> <json-file>" >&2
      exit 2
    fi
    validate_doc "$1" "$2"
    ;;
esac
