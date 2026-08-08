#!/bin/bash
# calc-executive-load.sh — Executive Load formula (V4.0 Immutable Core).
#
#   E = (G * 0.06) + (Q * 0.12) + (I_sec / 25)
#
#   G     = number of active goals
#   Q     = pending decision queue depth
#   I_sec = cumulative inference time (seconds) over last 10 ticks
#   Tick  = one scheduler iteration
#
#   If E > 1.0 → clip at 1.0 (caller triggers load-reduction)
#   Targets: 0.35–0.60 desired, 0.75 hard ceiling, 1.0 clip
#
# Usage:
#   calc-executive-load.sh --goals N --queue N --i-sec N [--tick N] [--write PATH]
#   calc-executive-load.sh --from-workspace   # read G from pfc-state, Q/I from load state
#
# Output: JSON {E,G,Q,I_sec,tick,timestamp,clipped,band}

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
G=""
Q=""
I_SEC=""
TICK="${TICK:-0}"
WRITE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goals) G="$2"; shift 2 ;;
    --queue) Q="$2"; shift 2 ;;
    --i-sec) I_SEC="$2"; shift 2 ;;
    --tick) TICK="$2"; shift 2 ;;
    --write) WRITE_PATH="$2"; shift 2 ;;
    --from-workspace)
      PFC="${WORKSPACE}/memory/pfc-state.json"
      LOAD="${WORKSPACE}/memory/executive-load.json"
      QUEUE_FILE="${WORKSPACE}/memory/decision-queue.json"
      if [ -f "$PFC" ]; then
        G=$(jq '[.goals[]? | select(.status=="active")] | length' "$PFC" 2>/dev/null || echo 0)
      else
        G=0
      fi
      if [ -f "$QUEUE_FILE" ]; then
        Q=$(jq 'if type=="array" then length else (.pending // .queue // []) | length end' "$QUEUE_FILE" 2>/dev/null || echo 0)
      else
        Q=0
      fi
      if [ -f "$LOAD" ]; then
        # Prefer rolling window of last 10 tick inference samples if present
        I_SEC=$(jq '
          if (.inference_window | type == "array") then
            (.inference_window[-10:] | map(.seconds // 0) | add // 0)
          else
            (.I_sec // 0)
          end
        ' "$LOAD" 2>/dev/null || echo 0)
        TICK=$(jq -r '.tick // 0' "$LOAD" 2>/dev/null || echo 0)
      else
        I_SEC=0
      fi
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "${G}" ] || [ -z "${Q}" ] || [ -z "${I_SEC}" ]; then
  echo "Usage: $0 --goals N --queue N --i-sec N [--tick N] [--write PATH]" >&2
  echo "   or: $0 --from-workspace [--write PATH]" >&2
  exit 2
fi

# Compute E with python for float precision
RESULT=$(G="$G" Q="$Q" I_SEC="$I_SEC" TICK="$TICK" python3 - <<'PY'
import json, os, math
from datetime import datetime, timezone

G = float(os.environ["G"])
Q = float(os.environ["Q"])
I = float(os.environ["I_SEC"])
tick = int(float(os.environ.get("TICK") or 0))

E_raw = (G * 0.06) + (Q * 0.12) + (I / 25.0)
clipped = E_raw > 1.0
E = 1.0 if clipped else E_raw

if E < 0.35:
    band = "underutilized"
elif E <= 0.60:
    band = "desired"
elif E <= 0.75:
    band = "elevated"
elif E < 1.0:
    band = "hard_ceiling_zone"
else:
    band = "clipped"

out = {
    "E": round(E, 6),
    "E_raw": round(E_raw, 6),
    "G": int(G),
    "Q": int(Q),
    "I_sec": round(I, 6),
    "tick": tick,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "clipped": clipped,
    "band": band,
    "thresholds": {
        "desired_min": 0.35,
        "desired_max": 0.60,
        "hard_ceiling": 0.75,
        "clip": 1.0,
    },
    "load_reduction_recommended": E >= 0.75 or clipped,
}
print(json.dumps(out))
PY
)

echo "$RESULT"

if [ -n "$WRITE_PATH" ]; then
  mkdir -p "$(dirname "$WRITE_PATH")"
  tmp="${WRITE_PATH}.tmp.$$"
  echo "$RESULT" > "$tmp"
  mv "$tmp" "$WRITE_PATH"
fi
