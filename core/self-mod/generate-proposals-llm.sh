#!/bin/bash
# generate-proposals-llm.sh — LLM-backed self-mod proposal generator.
#
# Prefers local llama-server OpenAI API (http://127.0.0.1:8080/v1) when healthy.
# Optional Hermes path when --provider is set. OpenRouter only if explicitly requested
# (never as silent default when LLM_LOCAL_ONLY=1).
#
# Emits a pipeline-consumable proposal JSON after check-target validation.
# On parse failure: exits non-zero and leaves raw model output under
# memory/self-mod/llm-raw/ — does NOT hand-construct proposal content.
#
# Usage:
#   generate-proposals-llm.sh [--suite-root PATH] [--workspace PATH]
#     [--module NAME] [--target RELPATH]
#     [--local-url URL] [--model MODEL_ID]
#     [--provider hermes|openrouter|llamaserver]
#     [--store] [--dry-run]
#
# Env: WORKSPACE, LLM_LOCAL_ONLY=1, LLM_PROPOSAL_TIMEOUT, LOCAL_LLM_URL

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SUITE_ROOT="$ROOT"
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
MODULE=""
TARGET_FORCE=""
PROVIDER=""
MODEL="${HERMES_MODEL:-}"
LOCAL_URL="${LOCAL_LLM_URL:-http://127.0.0.1:8080/v1}"
DRY=0
STORE=1
TIMEOUT="${LLM_PROPOSAL_TIMEOUT:-300}"
LOCAL_ONLY="${LLM_LOCAL_ONLY:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-root) SUITE_ROOT="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --module) MODULE="$2"; shift 2 ;;
    --target) TARGET_FORCE="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --local-url) LOCAL_URL="$2"; shift 2 ;;
    --dry-run) DRY=1; STORE=0; shift ;;
    --no-store) STORE=0; shift ;;
    --store) STORE=1; shift ;;
    --allow-cloud) LOCAL_ONLY=0; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

export WORKSPACE
CHECK="$SELF_DIR/check-target.sh"
STORE_SH="$SELF_DIR/proposal-store.sh"

mapfile -t MODULES < <(
  for m in "$SUITE_ROOT"/skills/*/capability-manifest.json; do
    [ -f "$m" ] || continue
    imm=$(jq -r .immutable "$m")
    [ "$imm" = "false" ] || continue
    jq -r .module "$m"
  done
)

if [ -n "$MODULE" ]; then
  ok=0
  for m in "${MODULES[@]}"; do [ "$m" = "$MODULE" ] && ok=1; done
  [ "$ok" -eq 1 ] || { echo "module not allowed: $MODULE" >&2; exit 1; }
  TARGET_MODULE="$MODULE"
else
  TARGET_MODULE=""
  for pref in cerebellum-memory insula-memory social-memory heartbeat-memory; do
    for m in "${MODULES[@]}"; do
      if [ "$m" = "$pref" ]; then TARGET_MODULE="$pref"; break 2; fi
    done
  done
  TARGET_MODULE="${TARGET_MODULE:-${MODULES[0]}}"
fi

if [ -n "$TARGET_FORCE" ]; then
  TARGET_REL="$TARGET_FORCE"
else
  # Prefer get-calibration / get-state style scripts over install.sh
  TARGET_REL=$(
    {
      find "$SUITE_ROOT/skills/$TARGET_MODULE" -type f \( -name 'get-*.sh' -o -name 'load-*.sh' \) ! -name 'decide.sh'
      find "$SUITE_ROOT/skills/$TARGET_MODULE" -type f -name '*.sh' ! -name 'decide.sh' ! -name 'install.sh'
    } 2>/dev/null | sed "s|^$SUITE_ROOT/||" | head -n 1
  )
fi
[ -n "$TARGET_REL" ] && [ -f "$SUITE_ROOT/$TARGET_REL" ] || {
  echo "no target file under $TARGET_MODULE" >&2
  exit 1
}

STUB=$(mktemp)
jq -nc --arg m "$TARGET_MODULE" --arg t "$TARGET_REL" --arg c "x" \
  '{proposal_id:"stub",module:$m,target_paths:[$t],content:$c}' > "$STUB"
bash "$CHECK" --suite-root "$SUITE_ROOT" --proposal "$STUB" >/dev/null || {
  echo "check-target rejected $TARGET_REL" >&2
  rm -f "$STUB"; exit 1
}
rm -f "$STUB"

CURRENT=$(cat "$SUITE_ROOT/$TARGET_REL")
CURRENT_CLIP=$(printf '%s' "$CURRENT" | head -c 8000)
COMMENT_LINE="# V4-llm-gen: model-proposed annotation ($(date -u +%Y-%m-%d))"

# Line-numbered excerpt (first 40 lines) for insert-based patch schema — shorter, reliable for local MoE.
NUMBERED=$(python3 - <<PY
from pathlib import Path
lines=Path("$SUITE_ROOT/$TARGET_REL").read_text().splitlines()
for i,l in enumerate(lines[:40],1):
    print(f"{i}|{l}")
print(f"... total_lines={len(lines)}")
PY
)

PROMPT=$(cat <<EOF
You are a JSON API. Reply with exactly one JSON object and nothing else.
No markdown fences. No tool calls. No prose before or after the JSON.

Required schema (use insert mode — do NOT emit the full file body):
{
  "proposal_id": "prop_<8+ alnum chars>",
  "module": "${TARGET_MODULE}",
  "target_paths": ["${TARGET_REL}"],
  "insert_after_line": <integer 1-40>,
  "insert_lines": ["# your new comment line only"],
  "estimated_components": {
    "task_success": 0.0,
    "resource_cost": 0.0,
    "error_rate": 0.0,
    "regression_penalty": 0.0
  }
}

Rules:
- module and target_paths MUST be exactly as shown.
- insert_after_line: line number AFTER which to insert (header comment region preferred).
- insert_lines: 1-3 lines only; must be shell comments starting with # ; no code changes.
- Prefer a comment similar to: ${COMMENT_LINE}
- Never target decide.sh or core/self-mod, core/locks, core/concurrency, core/sandbox, core/executive-load.

NUMBERED FILE EXCERPT (${TARGET_REL}):
${NUMBERED}
EOF
)

OUT_DIR="$WORKSPACE/memory/self-mod/llm-raw"
mkdir -p "$OUT_DIR"
TS=$(date -u +"%Y%m%dT%H%M%SZ")
RAW_FILE="$OUT_DIR/raw_${TS}.txt"
API_FILE="$OUT_DIR/api_${TS}.json"

# Detect local server
local_ok=0
if curl -sS -m 2 "${LOCAL_URL%/v1}/health" 2>/dev/null | grep -q ok \
  || curl -sS -m 2 "${LOCAL_URL}/models" 2>/dev/null | grep -q model; then
  local_ok=1
fi

if [ "$local_ok" -ne 1 ] && [ "$LOCAL_ONLY" = "1" ]; then
  echo "generate-proposals-llm: local server not healthy at $LOCAL_URL (LLM_LOCAL_ONLY=1)" >&2
  exit 1
fi

# Default model id from /v1/models if local
if [ -z "$MODEL" ] && [ "$local_ok" -eq 1 ]; then
  MODEL=$(curl -sS -m 3 "${LOCAL_URL}/models" | jq -r '.data[0].id // .models[0].name // empty')
fi
MODEL="${MODEL:-/home/cody/AI_MODELS/Carnice-Qwen3.6-MoE-35B-A3B-APEX-MTP-I-Quality.gguf}"

set +e
if [ "$local_ok" -eq 1 ] && { [ -z "$PROVIDER" ] || [ "$PROVIDER" = "llamaserver" ] || [ "$PROVIDER" = "local" ]; }; then
  # Direct OpenAI-compatible call (preferred for structured JSON; no Hermes tools)
  REQ=$(jq -nc \
    --arg model "$MODEL" \
    --arg sys "You output only valid JSON objects matching the user schema. Never use tools. Prefer content_b64 over raw content." \
    --arg user "$PROMPT" \
    '{
      model: $model,
      messages: [
        {role:"system", content:$sys},
        {role:"user", content:$user}
      ],
      temperature: 0.1,
      max_tokens: 1024,
      chat_template_kwargs: {enable_thinking: false}
    }')
  curl -sS -m "$TIMEOUT" "${LOCAL_URL}/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$REQ" >"$API_FILE" 2>"$RAW_FILE.err"
  RC=$?
  if [ "$RC" -eq 0 ]; then
    # Flatten assistant content to RAW_FILE for unified parser
    python3 - "$API_FILE" "$RAW_FILE" <<'PY'
import json,sys
from pathlib import Path
api=json.loads(Path(sys.argv[1]).read_text())
msg=api["choices"][0]["message"]
text=msg.get("content") or ""
# some models put JSON only in reasoning_content when thinking
if not text.strip().startswith("{") and msg.get("reasoning_content"):
    # try extract from reasoning
    text = msg.get("content") or msg.get("reasoning_content") or ""
Path(sys.argv[2]).write_text(text if text else json.dumps(api, indent=2))
print("extracted_chars", len(text))
PY
  else
    echo "local API call failed rc=$RC" >&2
    cat "$RAW_FILE.err" >&2 || true
  fi
elif [ "$PROVIDER" = "openrouter" ] && [ "$LOCAL_ONLY" != "1" ]; then
  timeout "$TIMEOUT" hermes chat -q "$PROMPT" --provider openrouter -m "${MODEL:-openrouter/auto}" \
    --source self-mod-generate >"$RAW_FILE" 2>&1
  RC=$?
  cp "$RAW_FILE" "$API_FILE"
else
  # Hermes path (may fail min-ctx or use tools — still recorded raw)
  HERMES_ARGS=(chat -q "$PROMPT" --source self-mod-generate)
  [ -n "$PROVIDER" ] && HERMES_ARGS+=(--provider "$PROVIDER")
  [ -n "$MODEL" ] && HERMES_ARGS+=(-m "$MODEL")
  timeout "$TIMEOUT" hermes "${HERMES_ARGS[@]}" >"$RAW_FILE" 2>&1
  RC=$?
  cp "$RAW_FILE" "$API_FILE"
fi
set -e

# Always keep raw evidence
cp -f "$API_FILE" "$OUT_DIR/latest_api.json" 2>/dev/null || true
cp -f "$RAW_FILE" "$OUT_DIR/latest_raw.txt" 2>/dev/null || true
echo "generate-proposals-llm: raw=$RAW_FILE api=$API_FILE" >&2

PROP_FILE=$(mktemp)
set +e
python3 - "$RAW_FILE" "$API_FILE" "$PROP_FILE" "$TARGET_MODULE" "$TARGET_REL" "$SUITE_ROOT" <<'PY'
import json, sys, re, hashlib, base64
from pathlib import Path

raw_path, api_path, out_path, module, target, suite = sys.argv[1:7]
raw = Path(raw_path).read_text(errors="replace") if Path(raw_path).exists() else ""
api_text = Path(api_path).read_text(errors="replace") if Path(api_path).exists() else ""

def try_load_json(s: str):
    s = s.strip()
    if not s:
        return None
    # strip fences
    if "```" in s:
        for part in s.split("```"):
            p = part.strip()
            if p.startswith("json"):
                p = p[4:].strip()
            if p.startswith("{"):
                s = p
                break
    start, end = s.find("{"), s.rfind("}")
    if start < 0 or end <= start:
        return None
    blob = s[start:end+1]
    # escape bare control chars inside strings
    out, in_s, esc = [], False, False
    for ch in blob:
        if in_s:
            if esc:
                out.append(ch); esc=False; continue
            if ch == "\\":
                out.append(ch); esc=True; continue
            if ch == '"':
                in_s=False; out.append(ch); continue
            if ch == "\n":
                out.append("\\n"); continue
            if ch == "\r":
                out.append("\\r"); continue
            if ch == "\t":
                out.append("\\t"); continue
            if ord(ch) < 32:
                continue
            out.append(ch)
        else:
            if ch == '"':
                in_s=True
            out.append(ch)
    return json.loads("".join(out))

prop = None
errs = []
for label, text in (("raw", raw), ("api_full", api_text)):
    try:
        # If api is OpenAI envelope, extract message content first
        if text.strip().startswith("{"):
            try:
                env = json.loads(text)
                if "choices" in env:
                    msg = env["choices"][0]["message"]
                    text2 = msg.get("content") or ""
                    prop = try_load_json(text2)
                    if prop:
                        break
            except Exception as e:
                errs.append(f"{label}_envelope:{e}")
        prop = try_load_json(text)
        if prop:
            break
    except Exception as e:
        errs.append(f"{label}:{e}")

if not prop:
    print("PARSE_FAIL " + "; ".join(errs), file=sys.stderr)
    sys.exit(2)

# Build content from model output:
# 1) content / content_b64 if complete, OR
# 2) insert_after_line + insert_lines applied to the live target file (model-specified patch ops)
content = prop.get("content")
if prop.get("content_b64"):
    try:
        b64 = re.sub(r"\s+", "", str(prop["content_b64"]))
        pad = (-len(b64)) % 4
        if pad:
            b64 += "=" * pad
        content = base64.b64decode(b64).decode("utf-8")
    except Exception as e:
        print(f"B64_FAIL {e}", file=sys.stderr)
        content = None

if (not content) and prop.get("insert_lines") is not None:
    src_path = Path(suite) / target
    if not src_path.is_file():
        print("NO_SOURCE", src_path, file=sys.stderr)
        sys.exit(4)
    lines = src_path.read_text().splitlines(keepends=True)
    try:
        after = int(prop.get("insert_after_line") or 0)
    except (TypeError, ValueError):
        print("BAD_INSERT_LINE", prop.get("insert_after_line"), file=sys.stderr)
        sys.exit(4)
    if after < 0 or after > len(lines):
        print("INSERT_OOB", after, len(lines), file=sys.stderr)
        sys.exit(4)
    ins = prop.get("insert_lines") or []
    if isinstance(ins, str):
        ins = [ins]
    if not ins or len(ins) > 5:
        print("BAD_INSERT_LINES", ins, file=sys.stderr)
        sys.exit(4)
    # Comments only — refuse code-looking inserts
    for L in ins:
        s = str(L).lstrip()
        if not s.startswith("#"):
            print("INSERT_NOT_COMMENT", L, file=sys.stderr)
            sys.exit(4)
    new_block = []
    for L in ins:
        L = str(L)
        if not L.endswith("\n"):
            L += "\n"
        new_block.append(L)
    content = "".join(lines[:after] + new_block + lines[after:])
    prop["patch_mode"] = "insert_lines"
    prop["model_insert_after_line"] = after
    prop["model_insert_lines"] = ins

if not content or not isinstance(content, str) or not content.strip():
    print("NO_CONTENT keys=" + ",".join(prop.keys()), file=sys.stderr)
    sys.exit(4)

# Enforce module/path allowlist (reject if model targeted outside)
prop["module"] = module
tps = prop.get("target_paths") or [target]
if isinstance(tps, str):
    tps = [tps]
norm = []
for t in tps:
    t = str(t).lstrip("./")
    if t.startswith(f"skills/{module}/"):
        norm.append(t)
if not norm:
    print("BAD_TARGET", tps, file=sys.stderr)
    sys.exit(5)
prop["target_paths"] = norm
if not str(prop.get("proposal_id", "")).startswith("prop"):
    prop["proposal_id"] = "prop_llm_" + hashlib.sha256(content.encode()).hexdigest()[:12]
prop["content"] = content if content.endswith("\n") else content + "\n"
# drop b64 from stored form after decode (keep optional)
prop.pop("content_b64", None)
prop.setdefault("estimated_components", {
    "task_success": 0.8, "resource_cost": 0.15, "error_rate": 0.05, "regression_penalty": 0.0
})
prop["proposer"] = "generate-proposals-llm"
prop["source"] = "llm"
prop["model_generated"] = True
# immutable guard
for t in prop["target_paths"]:
    if t.endswith("decide.sh") or t.startswith("core/self-mod/") or "/locks/" in t:
        print("IMMUTABLE", t, file=sys.stderr)
        sys.exit(6)
# minimal validity: shell scripts should start with shebang if .sh
if prop["target_paths"][0].endswith(".sh") and not prop["content"].lstrip().startswith("#!"):
    print("INVALID_SHELL_CONTENT", file=sys.stderr)
    sys.exit(7)

Path(out_path).write_text(json.dumps(prop, indent=2) + "\n")
print(out_path)
PY
PARSE_RC=$?
set -e

if [ "$PARSE_RC" -ne 0 ]; then
  echo "generate-proposals-llm: FAILED to parse model output (rc=$PARSE_RC)" >&2
  echo "  raw: $RAW_FILE" >&2
  echo "  api: $API_FILE" >&2
  # do not invent a proposal
  exit 1
fi

if ! bash "$CHECK" --suite-root "$SUITE_ROOT" --proposal "$PROP_FILE" | tee /tmp/llm_check.json; then
  echo "generate-proposals-llm: check-target rejected model proposal" >&2
  exit 1
fi

if [ "$DRY" -eq 1 ]; then
  cat "$PROP_FILE"
  exit 0
fi

if [ "$STORE" -eq 1 ]; then
  WORKSPACE="$WORKSPACE" bash "$STORE_SH" add --file "$PROP_FILE"
fi

mkdir -p "$WORKSPACE/memory/self-mod"
cp "$PROP_FILE" "$WORKSPACE/memory/self-mod/last-llm-proposal.json"
# evidence copies
cp "$PROP_FILE" "$OUT_DIR/parsed_${TS}.json"
cat "$PROP_FILE"
exit 0
