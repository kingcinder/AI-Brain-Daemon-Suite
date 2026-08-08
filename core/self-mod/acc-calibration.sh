#!/bin/bash
# acc-calibration.sh — ACC flag→error calibration (Stage-1 proprioception).
#
# Answers the question the README poses for keeping both ACC skills separate:
#   "how often does flagged uncertainty predict an actual error?"
#
# Joins the anterior-cingulate conflict flags (memory/conflict-state.json:
# .activeConflicts + .resolvedConflicts, each with type + firstSeen) against
# the acc-error corrections (memory/acc-state.json: .activePatterns +
# .resolved, each with firstSeen). A conflict "predicted" an error when an
# error pattern's firstSeen falls within [conflict.firstSeen,
# conflict.firstSeen + window_days] — flagged BEFORE the correction.
#
# Emits exactly one JSON object on stdout:
#   total_conflicts         flags with a usable firstSeen
#   flags_followed_by_error flags that had an error within the window
#   hit_rate                followed / total (0..1; 0 when no flags)
#   false_positive_rate     1 - hit_rate
#   total_errors            error patterns with a usable firstSeen
#   errors_unpredicted      errors with NO flag in the preceding window
#   by_type                 per-conflict-type {total, hits, hit_rate}
#   window_days             configurable lookahead (default 7)
#
# Any missing or unparseable source degrades to zeros — never aborts (same
# contract as health-context.sh). Read-only; never mutates state.
#
# Usage:
#   acc-calibration.sh [--workspace PATH] [--window-days N] [--json]
#
# Env:
#   WORKSPACE   defaults to $HOME/.hermes/workspace
#   ACC_CAL_WINDOW_DAYS   env override for the window (cli flag wins)

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
WINDOW_DAYS="${ACC_CAL_WINDOW_DAYS:-7}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --window-days) WINDOW_DAYS="$2"; shift 2 ;;
    --json) shift ;;  # JSON is the default output; flag accepted for explicitness
    *) shift ;;
  esac
done

MEM="$WORKSPACE/memory"

python3 - "$MEM" "$WINDOW_DAYS" <<'PY'
import json
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

mem = Path(sys.argv[1])
try:
    window_days = max(1, int(sys.argv[2] or 7))
except (ValueError, TypeError):
    window_days = 7  # never-fail contract: non-numeric window falls back


def load(rel, default):
    try:
        return json.loads((mem / rel).read_text())
    except (OSError, ValueError, TypeError):
        return default


def parse_ts(v):
    if not isinstance(v, str) or not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


conflict_state = load("conflict-state.json", {})
acc_state = load("acc-state.json", {})

# ── Collect conflicts (active map + resolved array, both carry type/firstSeen)
# isinstance guards: state shapes can drift (e.g. resolved as a list is a
# tolerated shape elsewhere in the suite) — skip non-dict containers rather
# than aborting, per the never-fail contract.
conflicts = []
active_conf = conflict_state.get("activeConflicts")
if isinstance(active_conf, dict):
    for cid, c in active_conf.items():
        ts = parse_ts(c.get("firstSeen") if isinstance(c, dict) else None)
        if ts:
            conflicts.append({"id": cid, "type": c.get("type", "unknown"), "firstSeen": ts})
resolved_conf = conflict_state.get("resolvedConflicts")
if isinstance(resolved_conf, list):
    for c in resolved_conf:
        if not isinstance(c, dict):
            continue
        ts = parse_ts(c.get("firstSeen"))
        if ts:
            conflicts.append({"id": c.get("id", "?"), "type": c.get("type", "unknown"), "firstSeen": ts})

# ── Collect errors (active map + resolved map, both keep firstSeen) ─────────
errors = []
active_pat = acc_state.get("activePatterns")
if isinstance(active_pat, dict):
    for name, e in active_pat.items():
        ts = parse_ts(e.get("firstSeen") if isinstance(e, dict) else None)
        if ts:
            errors.append({"pattern": name, "firstSeen": ts})
resolved_pat = acc_state.get("resolved")
if isinstance(resolved_pat, dict):
    for name, e in resolved_pat.items():
        ts = parse_ts(e.get("firstSeen") if isinstance(e, dict) else None)
        if ts:
            errors.append({"pattern": name, "firstSeen": ts})

window = timedelta(days=window_days)
total_by_type = {}
hits_by_type = {}
for c in conflicts:
    t = c["type"] or "unknown"
    total_by_type[t] = total_by_type.get(t, 0) + 1
    hit = any(c["firstSeen"] <= e["firstSeen"] <= c["firstSeen"] + window for e in errors)
    if hit:
        hits_by_type[t] = hits_by_type.get(t, 0) + 1

total = len(conflicts)
hits = sum(hits_by_type.values())
unpredicted = 0
for e in errors:
    preceded = any(e["firstSeen"] - window <= c["firstSeen"] <= e["firstSeen"] for c in conflicts)
    if not preceded:
        unpredicted += 1

by_type = {}
for t in sorted(total_by_type):
    tt = total_by_type[t]
    h = hits_by_type.get(t, 0)
    by_type[t] = {"total": tt, "hits": h, "hit_rate": round(h / tt, 3) if tt else 0.0}

out = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "window_days": window_days,
    "total_conflicts": total,
    "flags_followed_by_error": hits,
    "hit_rate": round(hits / total, 3) if total else 0.0,
    "false_positive_rate": round(1 - (hits / total), 3) if total else 0.0,
    "total_errors": len(errors),
    "errors_unpredicted": unpredicted,
    "by_type": by_type,
    "sources": {
        "conflict_state": str(mem / "conflict-state.json"),
        "acc_state": str(mem / "acc-state.json"),
    },
}
print(json.dumps(out, indent=2))
PY
