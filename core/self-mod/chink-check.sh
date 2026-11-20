#!/bin/bash
# chink-check.sh — the gap sensor (named by Dither, 2026-11-13).
#
# A "chink" is a gap in the armor: a recurring failure nobody owns, work
# dying in a deadletter, a queue backing up, a proposal class that keeps
# getting rejected, a stale artifact the new contract should have cleared.
# The chink check is NOT a gate — it blocks nothing. It is the genesis
# sensor for proposals: a chink at medium severity or above is what
# prompts Juno to author a proposal in the first place. The proposal then
# goes through the normal pipeline (check-target → evaluate → Juno's
# approval gate → deploy → rollback-on-breach) like any other.
#
# Read-only over $WORKSPACE/memory. Writes one report:
#   memory/self-mod/chinks-latest.json
# Exit 0 always — a sensor that fails the run would hide the gaps.
#
# Usage: chink-check.sh [--workspace PATH]
set -uo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
export CHINK_WORKSPACE="$WORKSPACE"

python3 - << 'PY'
import json, os, sys
from pathlib import Path

ws = Path(os.environ["CHINK_WORKSPACE"])
mem = ws / "memory"
chinks = []

def sev(score):
    return "high" if score >= 5 else ("medium" if score >= 3 else "low")

def add(kind, evidence, score, detail):
    chinks.append({
        "kind": kind,
        "evidence": evidence,
        "severity": sev(score),
        "score": score,
        "detail": detail,
        "suggested_proposal": f"Author a proposal addressing {kind}: {detail}",
    })

# 1) ACC active patterns: recurring failures no resolved pattern covers.
p = mem / "acc-state.json"
if p.exists():
    try:
        acc = json.loads(p.read_text())
        for name, pat in (acc.get("activePatterns") or {}).items():
            count = pat.get("count", 0)
            severity = pat.get("severity", "")
            score = count + (3 if severity == "critical" else 0)
            if count >= 3 or severity == "critical":
                add("recurring_failure", f"acc-state.json:{name}", score,
                    f"pattern '{name}' seen {count}x, severity={severity or 'n/a'}, still active")
    except Exception as e:
        add("sensor_blindness", "acc-state.json", 3, f"acc-state.json unreadable: {e}")

# 2) Spawn deadletter: work that died with nowhere to go.
for fname, kind in [("spawn-deadletter.jsonl", "deadletter"),
                    ("spawn-queue.jsonl", "queue_backlog")]:
    p = mem / fname
    if p.exists():
        n = sum(1 for line in p.read_text().splitlines() if line.strip())
        if n > 0:
            add(kind, fname, n if kind == "deadletter" else min(n, 4),
                f"{n} entr{'y' if n == 1 else 'ies'} in {fname}")

# 3) Pipeline evaluations: accepted=false in the latest run summary.
p = mem / "self-mod" / "pipeline-runs" / "latest.json"
if p.exists():
    try:
        run = json.loads(p.read_text())
        rejected = [e for e in run.get("evaluations", []) if e.get("accepted") is False]
        if rejected:
            add("rejected_proposals", "pipeline-runs/latest.json", len(rejected) + 2,
                f"{len(rejected)} proposal(s) rejected by evaluate in the latest run")
    except Exception:
        pass

# 4) Stale pre-M9 deferral marker: the new contract clears these on the
#    next cycle run; one still sitting here is a leftover gap.
p = mem / "self-mod" / "last-deferral.json"
if p.exists():
    add("stale_artifact", "self-mod/last-deferral.json", 3,
        "pre-M9 deferral marker still present; next cycle run should have cleared it")

# 5) Sensor blindness: an expected signal file missing entirely is itself
#    a chink — the check cannot see that region at all.
for fname in ["acc-state.json"]:
    if not (mem / fname).exists():
        add("sensor_blindness", fname, 4, f"{fname} missing — region invisible to the check")

chinks.sort(key=lambda c: -c["score"])
report = {
    "check": "chink-check",
    "workspace": str(ws),
    "chink_count": len(chinks),
    "actionable": sum(1 for c in chinks if c["severity"] in ("medium", "high")),
    "chinks": chinks,
}
out = mem / "self-mod" / "chinks-latest.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
PY
exit 0
