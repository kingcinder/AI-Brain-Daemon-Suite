#!/usr/bin/env bash
# scripts/encode-pipeline.sh — Local-LLM-based conflict detection from conversation transcripts.
#
# Scans recent exchanges for conflicts, contradictions, and ambiguities, then
# updates conflict-state.json. Uses the same local llm-call.sh utility as
# every other skill in the suite (see prefrontal-cortex-memory's
# semantic-match.sh for the reference pattern this follows) instead of
# calling the Anthropic cloud API directly. No API key, no per-call cost, no
# external network dependency — consistent with the rest of the stack.
#
# Requires: a local OpenAI-compatible LLM server (llama.cpp server, Ollama,
# LM Studio, vLLM, etc.) reachable at $LLM_BASE_URL (default
# http://localhost:1234/v1 — same env convention as llm-call.sh everywhere
# else). If the local server is unreachable, this fails open: it logs a
# warning and skips, exactly like semantic-match.sh's fallback path, rather
# than treating a down/slow local model as a hard error.
#
# Designed to run on the daemon's schedule (see BRAIN_DAEMON_SCHEDULE.md).

set -euo pipefail

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.hermes/workspace}}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$WORKSPACE/memory/conflict-state.json"
PROMPT_FILE="$SKILL_DIR/prompts/detect-conflicts.md"
LLM_CALL="$SKILL_DIR/scripts/llm-call.sh"
SAFE_WRITE="$SKILL_DIR/scripts/safe-write.sh"

if [ ! -x "$LLM_CALL" ]; then
  echo "⚡ encode-pipeline: llm-call.sh not found/executable at $LLM_CALL — skipping." >&2
  exit 0
fi

# ── Extract exchanges since watermark ─────────────────────────────────────────
EXCHANGES=$("$SKILL_DIR/scripts/preprocess-exchanges.sh")
EXCHANGE_COUNT=$(echo "$EXCHANGES" | jq 'length' 2>/dev/null || echo 0)

# Integrative State Layer: under acute stress (stressIndex > 0.6) conflicts
# are flagged on thinner evidence — exchange threshold drops 2 -> 1.
# NOTE: this file uses jq only (no bc anywhere in it) — use jq for the
# comparison, not bc, to avoid introducing a new dependency in this file.
MIN_EXCHANGES=2
if [ -x "$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" ]; then
    STRESS_INDEX=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --composite stressIndex 2>/dev/null || echo "0.5")
    if jq -e --argjson s "$STRESS_INDEX" '$s > 0.6' /dev/null > /dev/null 2>&1; then
        MIN_EXCHANGES=1
    fi
fi

if [ "$EXCHANGE_COUNT" -lt "$MIN_EXCHANGES" ]; then
  echo "⚡ encode-pipeline: insufficient exchanges ($EXCHANGE_COUNT) — skipping."
  exit 0
fi

echo "⚡ encode-pipeline: analyzing $EXCHANGE_COUNT exchanges for conflicts..."

if [ ! -f "$PROMPT_FILE" ]; then
  echo "⚡ encode-pipeline: prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi
SYSTEM_PROMPT=$(cat "$PROMPT_FILE")

CURRENT_LOAD=$(jq -r '.conflictLoad' "$STATE_FILE")
CURRENT_FLAGS=$(jq -c '.attentionFlags' "$STATE_FILE")

# Build the user message entirely with jq — not python triple-quoted string
# interpolation like the old cloud version did. Transcript content can
# contain arbitrary quotes/backslashes; jq's --argjson/--arg handle that
# safely, a python f-string built from raw shell interpolation does not.
USER_PROMPT=$(jq -n \
  --argjson exchanges "$EXCHANGES" \
  --arg load "$CURRENT_LOAD" \
  --argjson flags "$CURRENT_FLAGS" '
  "# Conversation Exchanges to Analyze\n\n" +
  (($exchanges | to_entries) | map("## Exchange \(.key + 1) [\(.value.role)]\n\(.value.content)\n") | join("\n")) +
  "\n# Current State\n" +
  "conflict_load: \($load)\n" +
  "attention_flags: \($flags)\n\n" +
  "Analyze these exchanges and return JSON as specified in the system prompt."
')

# ── Call the local LLM — same utility, same env overrides, same fail-open
#    contract (non-zero exit = caller must degrade gracefully) as every
#    other caller of llm-call.sh in the suite. ────────────────────────────────
# ── Call the local LLM — same utility, same env overrides, same fail-open
#    contract (non-zero exit = caller must degrade gracefully) as every
#    other caller of llm-call.sh in the suite. ────────────────────────────────
# NOTE: captured via if/then, not `RAW_OUTPUT=$(...); LLM_STATUS=$?` — under
# `set -e`, that second form kills this whole script the instant llm-call.sh
# returns non-zero, before LLM_STATUS is ever read. This is the exact
# footgun semantic-match.sh's own header comment warns callers about.
if RAW_OUTPUT=$("$LLM_CALL" --system "$SYSTEM_PROMPT" --user "$USER_PROMPT" \
  --timeout "${LLM_TIMEOUT:-30}" --retries "${LLM_RETRIES:-1}" --json 2>"$ENC_ERR"); then
  LLM_STATUS=0
else
  LLM_STATUS=$?
fi

if [ "$LLM_STATUS" -ne 0 ]; then
  echo "⚡ encode-pipeline: local LLM call failed — $(tail -1 "$ENC_ERR" 2>/dev/null) — no updates applied." >&2
  rm -f "$ENC_ERR"
  exit 0
fi
rm -f "$ENC_ERR"

# Some local servers/models wrap JSON in ```json fences even in JSON mode — strip if present.
CLEANED=$(echo "$RAW_OUTPUT" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

if ! echo "$CLEANED" | jq -e 'has("conflicts") or has("attention_flags") or has("uncertainty_zones")' > /dev/null 2>&1; then
  echo "⚡ encode-pipeline: response wasn't valid JSON with the expected keys — no updates applied." >&2
  exit 0
fi

# Strict validation, same discipline as semantic-match.sh: never trust a raw
# LLM response wholesale. Drop any entry missing its required fields rather
# than passing garbage through to log-conflict.sh / flag-attention.sh.
VALID_TYPES='["factual","instruction","context","uncertainty","intent","knowledge_gap"]'
VALID_SEVERITIES='["low","moderate","high"]'

CONFLICTS=$(echo "$CLEANED" | jq -c --argjson validTypes "$VALID_TYPES" --argjson validSev "$VALID_SEVERITIES" '
  [ .conflicts[]? | select((.description | type == "string") and (.description | length > 0)) |
    (.type as $t | .severity as $s |
      {
        type: (if ($t | type == "string") and ($validTypes | any(. == $t)) then $t else "factual" end),
        description: .description,
        severity: (if ($s | type == "string") and ($validSev | any(. == $s)) then $s else "moderate" end),
        resolution_hint: (.resolution_hint // empty)
      })
  ]' 2>/dev/null || echo '[]')

ATTENTION=$(echo "$CLEANED" | jq -c '
  [ .attention_flags[]? | select((.topic | type == "string") and (.topic | length > 0)) |
    { topic: .topic, reason: (.reason // "flagged by encode-pipeline") }
  ]' 2>/dev/null || echo '[]')

ZONES=$(echo "$CLEANED" | jq -c '.uncertainty_zones // []' 2>/dev/null || echo '[]')

CONFLICT_COUNT=$(echo "$CONFLICTS" | jq 'length')
ATTENTION_COUNT=$(echo "$ATTENTION" | jq 'length')
ZONE_COUNT=$(echo "$ZONES" | jq 'length')

echo "⚡ encode-pipeline: found $CONFLICT_COUNT conflict(s), $ATTENTION_COUNT flag(s), $ZONE_COUNT zone(s)"

while IFS= read -r c; do
  [ -z "$c" ] && continue
  TYPE=$(echo "$c" | jq -r '.type')
  DESC=$(echo "$c" | jq -r '.description')
  SEV=$(echo "$c" | jq -r '.severity')
  HINT=$(echo "$c" | jq -r '.resolution_hint // empty')
  CMD=("$SKILL_DIR/scripts/log-conflict.sh" --type "$TYPE" --description "$DESC" --severity "$SEV")
  [ -n "$HINT" ] && CMD+=(--resolution-hint "$HINT")
  "${CMD[@]}" || true
done < <(echo "$CONFLICTS" | jq -c '.[]')

while IFS= read -r flag; do
  [ -z "$flag" ] && continue
  TOPIC=$(echo "$flag" | jq -r '.topic')
  REASON=$(echo "$flag" | jq -r '.reason')
  "$SKILL_DIR/scripts/flag-attention.sh" --add "$TOPIC" --reason "$REASON" || true
done < <(echo "$ATTENTION" | jq -c '.[]')

# ── Update encoding stats — lock-guarded via safe-write.sh, same pattern used
#    across the suite, instead of an unguarded read/mutate/write. ─────────────
if [ -x "$SAFE_WRITE" ]; then
  MUTATE_SCRIPT=$(mktemp)
ENC_ERR=$(mktemp "${TMPDIR:-/tmp}/aibrain-encode-err.XXXXXX")
  trap 'rm -f "$MUTATE_SCRIPT"' EXIT
  cat > "$MUTATE_SCRIPT" << 'MUTATE_EOF'
#!/bin/bash
set -euo pipefail
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg now "$NOW" \
  '.stats.encodingRuns = (.stats.encodingRuns // 0) + 1 | .lastUpdated = $now' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
MUTATE_EOF
  chmod +x "$MUTATE_SCRIPT"
  "$SAFE_WRITE" "$STATE_FILE" "$MUTATE_SCRIPT"
else
  # safe-write.sh missing — fall back to the old unguarded write rather than
  # failing the whole run over a lock utility that isn't there.
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  UPDATED=$(jq --arg now "$NOW" \
    '.stats.encodingRuns = (.stats.encodingRuns // 0) + 1 | .lastUpdated = $now' \
    "$STATE_FILE")
  echo "$UPDATED" > "$STATE_FILE"
fi

# ── Closed-loop: uncertainty zones → VTA anticipation ─────────────────────
# When the ACC detects uncertainty (ambiguity in the world, unknown topics),
# flag those topics for the VTA's anticipatory reward system so the brain
# learns to seek resolution of what it doesn't understand.
if [ "$ZONE_COUNT" -gt 0 ]; then
    ANTICIPATE_SCRIPT="$SKILL_DIR/../vta-memory/scripts/anticipate.sh"
    if [ -x "$ANTICIPATE_SCRIPT" ]; then
        while IFS= read -r zone; do
            [ -z "$zone" ] && continue
            TOPIC=$(echo "$zone" | jq -r '.topic // empty' 2>/dev/null)
            [ -z "$TOPIC" ] && continue
            REASON=$(echo "$zone" | jq -r '.reason // "ACC-flagged uncertainty"' 2>/dev/null)
            "$ANTICIPATE_SCRIPT" --topic "$TOPIC" --reason "$REASON" --source "acc_encode" 2>/dev/null || true
        done < <(echo "$ZONES" | jq -c '.[]')
    fi
fi

# ── Log event ─────────────────────────────────────────────────────────────────
"$SKILL_DIR/scripts/log-event.sh" \
  encoding \
  "exchanges=$EXCHANGE_COUNT" \
  "load=$(jq -r '.conflictLoad' "$STATE_FILE")" 2>/dev/null || true

echo "⚡ encode-pipeline: done."
