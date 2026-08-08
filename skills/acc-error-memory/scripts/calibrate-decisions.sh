#!/bin/bash
# calibrate-decisions.sh — ROADMAP M4: feed decisionLog outcomes into ACC
# error calibration.
#
# PFC's decisionLog (written by decide.sh) records every arbitration the
# agent made: chosen option, reasoning, context. ACC error memory tracks
# error patterns and lessons. This script correlates the two:
#   - For each decisionLog entry, checks whether its chosen option/context
#     text overlaps an active ACC error pattern (or a pattern that was later
#     logged as a goal_failed lesson), i.e. "did we decide to do the thing
#     that then went wrong?"
#   - Writes a calibration snapshot to $WORKSPACE/memory/acc-calibration.json
#     and prints a short human summary.
#
# This is the calibration signal the audit named: "how often does flagged
# uncertainty predict an actual error?" — turned into a measurable number
# that the executive/proposal cycle can consume.
#
# Usage:
#   calibrate-decisions.sh [--workspace PATH] [--recent N]
#
# Output:
#   JSON snapshot at $WORKSPACE/memory/acc-calibration.json:
#   {
#     "decisionsReviewed": N,
#     "errorLinkedDecisions": M,
#     "calibrationRatio": M/N,          # 0.0..1.0
#     "flaggedUncertainty": K,          # decisions whose reasoning mentions conflict/uncertain
#     "uncertaintyThatErrored": E,      # of those, how many linked to an error pattern
#     "uncertaintyCalibration": E/K,    # the "flagged uncertainty -> error" precision
#     "lastUpdated": "..."
#   }

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
PFC="$WORKSPACE/memory/pfc-state.json"
ACC="$WORKSPACE/memory/acc-state.json"
OUT="$WORKSPACE/memory/acc-calibration.json"
RECENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --recent) RECENT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$WORKSPACE/memory"

# Missing inputs are a valid "nothing to calibrate yet" — not an error.
[ -f "$PFC" ] || { echo '{"decisionsReviewed":0,"errorLinkedDecisions":0,"calibrationRatio":0.0,"flaggedUncertainty":0,"uncertaintyThatErrored":0,"uncertaintyCalibration":0.0,"note":"no pfc-state.json yet"}' > "$OUT"; cat "$OUT"; exit 0; }
[ -f "$ACC" ] || { echo '{"decisionsReviewed":0,"errorLinkedDecisions":0,"calibrationRatio":0.0,"flaggedUncertainty":0,"uncertaintyThatErrored":0,"uncertaintyCalibration":0.0,"note":"no acc-state.json yet"}' > "$OUT"; cat "$OUT"; exit 0; }

PFC="$PFC" ACC="$ACC" OUT="$OUT" RECENT="$RECENT" python3 << 'PY'
import json, os
from pathlib import Path
from datetime import datetime, timezone

pfc_path = Path(os.environ["PFC"])
acc_path = Path(os.environ["ACC"])
out_path = Path(os.environ["OUT"])
recent = int(os.environ.get("RECENT") or 0)

pfc = json.loads(pfc_path.read_text())
acc = json.loads(acc_path.read_text())

log = pfc.get("decisionLog") or []
if recent > 0:
    log = log[:recent]

# ACC error pattern names (active + resolved) — the "things that went wrong"
patterns = set()
for bucket in ("activePatterns", "resolved"):
    obj = acc.get(bucket) or {}
    for key in obj:
        if isinstance(key, str):
            patterns.add(key.lower())
        else:
            patterns.add(str(key).lower())

def words(text):
    import re
    return {w for w in re.findall(r"[a-z0-9]+", str(text).lower()) if len(w) > 2}

# For each decision, does its chosen/context/reasoning overlap a known error
# pattern? Also: did the reasoning mention uncertainty/conflict (ACC signal)?
error_linked = 0
flagged = 0
flagged_errored = 0
for entry in log:
    text = " ".join([
        str(entry.get("chosen") or ""),
        str(entry.get("context") or ""),
        str(entry.get("reasoning") or ""),
    ])
    tw = words(text)
    hit = any(any(w in words(p) for w in tw) or p in text.lower() for p in patterns)
    uncertainty = any(k in text.lower() for k in
                      ("uncertain", "conflict", "ambiguous", "not sure", "flagged", "risk"))
    if uncertainty:
        flagged += 1
    if hit:
        error_linked += 1
        if uncertainty:
            flagged_errored += 1

n = len(log)
cal = dict(
    decisionsReviewed=n,
    errorLinkedDecisions=error_linked,
    calibrationRatio=round(error_linked / n, 4) if n else 0.0,
    flaggedUncertainty=flagged,
    uncertaintyThatErrored=flagged_errored,
    uncertaintyCalibration=round(flagged_errored / flagged, 4) if flagged else 0.0,
    lastUpdated=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
)
out_path.write_text(json.dumps(cal, indent=2) + "\n")
print(json.dumps(cal, indent=2))
PY
