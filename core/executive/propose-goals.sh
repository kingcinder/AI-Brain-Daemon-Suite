#!/bin/bash
# propose-goals.sh — Phase 2 executive goal proposal generator / promoter.
#
# Reads isolated reflection output (or runs isolated-reflect if missing) and
# appends ranked goal proposals to memory/executive/goal-proposals.jsonl.
#
# By default does NOT mutate pfc-state.json. With --promote, applies top
# proposals as active goals under hard caps (max active goals, min confidence,
# executive-load gate).
#
# Never modifies decide.sh or other Immutable Core modules.
#
# Usage:
#   propose-goals.sh [--workspace PATH] [--reflection PATH] [--promote]
#                    [--max-active N] [--min-confidence F] [--max-promote N]
#                    [--dry-run]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
REFLECTION=""
PROMOTE=0
DRY_RUN=0
MAX_ACTIVE="${MAX_ACTIVE_GOALS:-5}"
MIN_CONF="${MIN_PROPOSAL_CONFIDENCE:-0.65}"
MAX_PROMOTE="${MAX_PROMOTE_PER_CYCLE:-2}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --reflection) REFLECTION="$2"; shift 2 ;;
    --promote) PROMOTE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --max-active) MAX_ACTIVE="$2"; shift 2 ;;
    --min-confidence) MIN_CONF="$2"; shift 2 ;;
    --max-promote) MAX_PROMOTE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--workspace PATH] [--reflection PATH] [--promote] [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

MEM="$WORKSPACE/memory"
EXEC_DIR="$MEM/executive"
PROP_LOG="$EXEC_DIR/goal-proposals.jsonl"
PFC="$MEM/pfc-state.json"
mkdir -p "$EXEC_DIR"

if [ -z "$REFLECTION" ] || [ ! -f "$REFLECTION" ]; then
  if [ -f "$EXEC_DIR/reflections/latest.json" ]; then
    REFLECTION="$EXEC_DIR/reflections/latest.json"
  else
    REFLECTION=$(bash "$ROOT/core/executive/isolated-reflect.sh" --workspace "$WORKSPACE")
  fi
fi

if [ ! -f "$REFLECTION" ]; then
  echo "propose-goals: no reflection file" >&2
  exit 1
fi

# Rank + append proposals
RESULT=$(
  WORKSPACE="$WORKSPACE" REFLECTION="$REFLECTION" PROP_LOG="$PROP_LOG" \
  PROMOTE="$PROMOTE" DRY_RUN="$DRY_RUN" MAX_ACTIVE="$MAX_ACTIVE" \
  MIN_CONF="$MIN_CONF" MAX_PROMOTE="$MAX_PROMOTE" PFC="$PFC" \
  ROOT="$ROOT" python3 - <<'PY'
import json, os, sys
from pathlib import Path
from datetime import datetime, timezone

reflection_path = Path(os.environ["REFLECTION"])
prop_log = Path(os.environ["PROP_LOG"])
pfc_path = Path(os.environ["PFC"])
promote = os.environ.get("PROMOTE") == "1"
dry_run = os.environ.get("DRY_RUN") == "1"
max_active = int(os.environ.get("MAX_ACTIVE", "5"))
min_conf = float(os.environ.get("MIN_CONF", "0.65"))
max_promote = int(os.environ.get("MAX_PROMOTE", "2"))
root = Path(os.environ["ROOT"])

data = json.loads(reflection_path.read_text())
proposals = list(data.get("goal_proposals") or [])
# Rank: confidence * priority desc
proposals.sort(key=lambda p: (float(p.get("confidence") or 0) * float(p.get("priority") or 0)), reverse=True)

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
prop_log.parent.mkdir(parents=True, exist_ok=True)

written = []
for p in proposals:
    entry = {
        **p,
        "ranked_at": now,
        "reflection_file": str(reflection_path),
        "score": round(float(p.get("confidence") or 0) * float(p.get("priority") or 0), 6),
        "lifecycle": "queued",
    }
    if not dry_run:
        with open(prop_log, "a") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
    written.append(entry)

# Optional provenance for batch
if written and not dry_run:
    prov = root / "core" / "provenance" / "log-provenance.sh"
    if prov.is_file():
        import subprocess
        batch_id = f"goalbatch_{now.replace(':','').replace('-','')}"
        content = json.dumps([w.get("proposal_id") for w in written])
        subprocess.run(
            ["bash", str(prov), "append",
             "--proposal-id", batch_id,
             "--content", content,
             "--parent-hash", "null",
             "--proposer", "propose-goals",
             "--reviewer", "phase2",
             "--utility-score", str(written[0].get("score") or 0),
             "--rollback-status", "none"],
            check=False,
            capture_output=True,
            env={**os.environ, "WORKSPACE": os.environ.get("WORKSPACE", "")},
        )

promoted = []
skipped_reason = None

if promote:
    # Load / ensure PFC state
    if pfc_path.is_file():
        pfc = json.loads(pfc_path.read_text())
    else:
        pfc = {
            "version": "1.0",
            "lastUpdated": now,
            "executiveLoad": 0.0,
            "goals": [],
            "inhibitions": [],
            "decisionLog": [],
        }

    goals = pfc.get("goals") if isinstance(pfc.get("goals"), list) else []
    active = [g for g in goals if isinstance(g, dict) and g.get("status") == "active"]
    active_descs = {str(g.get("description") or "").strip().lower() for g in active}

    # Executive load gate
    eload_path = Path(os.environ["WORKSPACE"]) / "memory" / "executive-load.json"
    E = 0.0
    if eload_path.is_file():
        try:
            E = float(json.loads(eload_path.read_text()).get("E") or 0)
        except Exception:
            E = 0.0
    if E >= 0.75:
        skipped_reason = f"executive_load_gate E={E:.3f}>=0.75"
    else:
        slots = max(0, max_active - len(active))
        budget = min(slots, max_promote)
        for p in proposals:
            if budget <= 0:
                break
            conf = float(p.get("confidence") or 0)
            if conf < min_conf:
                continue
            desc = str(p.get("description") or "").strip()
            if not desc:
                continue
            if desc.lower() in active_descs:
                continue
            # word-overlap dedupe
            tokens = set(desc.lower().split())
            dup = False
            for ad in active_descs:
                at = set(ad.split())
                if tokens and at and len(tokens & at) / max(1, len(tokens)) >= 0.6:
                    dup = True
                    break
            if dup:
                continue
            gid = p.get("proposal_id") or f"goal_{now}"
            new_goal = {
                "id": gid if str(gid).startswith("goal") else f"goal_{gid}",
                "description": desc,
                "priority": float(p.get("priority") or 0.5),
                "status": "active",
                "deadline": "",
                "createdAt": now,
                "source": "executive.propose-goals",
                "proposal_id": p.get("proposal_id"),
            }
            if not dry_run:
                goals.append(new_goal)
            promoted.append(new_goal)
            active_descs.add(desc.lower())
            budget -= 1

        if not dry_run and promoted:
            pfc["goals"] = goals
            pfc["lastUpdated"] = now
            pfc_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = pfc_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(pfc, indent=2, sort_keys=True) + "\n")
            tmp.replace(pfc_path)

out = {
    "queued": len(written),
    "proposals": [{"proposal_id": w.get("proposal_id"), "score": w.get("score"), "description": w.get("description")} for w in written],
    "promoted": [{"id": g.get("id"), "description": g.get("description")} for g in promoted],
    "promote_requested": promote,
    "dry_run": dry_run,
    "skipped_reason": skipped_reason,
    "reflection": str(reflection_path),
    "proposal_log": str(prop_log),
}
print(json.dumps(out, indent=2, sort_keys=True))
PY
)

echo "$RESULT"
