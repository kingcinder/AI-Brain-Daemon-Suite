#!/bin/bash
# score-utility.sh — Phase 3 Utility Function scorer (initial weights).
#
# U = α(Task Success) - β(Resource Cost) - γ(Error Rate) - δ(Regression Penalty)
# α=0.40 β=0.15 γ=0.25 δ=0.20  (L1 normalized)
#
# Usage:
#   score-utility.sh --task-success 0.8 --resource-cost 0.2 --error-rate 0.1 --regression-penalty 0.0
# Output: JSON {U, components, weights}

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEIGHTS_FILE="${UTILITY_WEIGHTS:-$SCRIPT_DIR/utility-weights.json}"

TS="" RC="" ER="" RP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-success) TS="$2"; shift 2 ;;
    --resource-cost) RC="$2"; shift 2 ;;
    --error-rate) ER="$2"; shift 2 ;;
    --regression-penalty) RP="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$TS" ] || [ -z "$RC" ] || [ -z "$ER" ] || [ -z "$RP" ]; then
  echo "Usage: $0 --task-success N --resource-cost N --error-rate N --regression-penalty N" >&2
  exit 2
fi

python3 - "$TS" "$RC" "$ER" "$RP" "$WEIGHTS_FILE" <<'PY'
import json, sys
ts, rc, er, rp = map(float, sys.argv[1:5])
weights_path = sys.argv[5]
try:
    w = json.load(open(weights_path))["weights"]
    a = float(w["alpha_task_success"])
    b = float(w["beta_resource_cost"])
    g = float(w["gamma_error_rate"])
    d = float(w["delta_regression_penalty"])
except Exception:
    a, b, g, d = 0.40, 0.15, 0.25, 0.20

# Clamp components to [0,1]
def clamp(x):
    return max(0.0, min(1.0, x))

ts, rc, er, rp = map(clamp, (ts, rc, er, rp))
U = a*ts - b*rc - g*er - d*rp
print(json.dumps({
    "U": round(U, 6),
    "components": {
        "task_success": ts,
        "resource_cost": rc,
        "error_rate": er,
        "regression_penalty": rp,
    },
    "weights": {
        "alpha": a, "beta": b, "gamma": g, "delta": d,
    },
    "formula": "U = α(TS) - β(RC) - γ(ER) - δ(RP)",
}, indent=2))
PY
