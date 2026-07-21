#!/bin/bash
# isolated-reflect.sh — Phase 2 isolated reflection (V4.0 Reflection Independence).
#
# Generates reflection proposals from a *read-only* isolated context:
#   1. Snapshot selected memory signals into a temp isolation tree
#   2. chmod a-w so the analysis process cannot mutate the snapshot
#   3. Synthesize offline reflection (no write path into live WORKSPACE)
#   4. Write reflection JSON only to --out (orchestrator-controlled)
#
# Does NOT call decide.sh. Does NOT mutate pfc-state.json.
# Optional --with-inference is reserved for a future spawn path; default is offline.
#
# Usage:
#   isolated-reflect.sh [--workspace PATH] [--out PATH] [--with-inference]
# Env:
#   WORKSPACE  default ~/.openclaw/workspace
#
# Exit 0 on success; prints path to reflection JSON on stdout last line.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
OUT_DIR=""
WITH_INFERENCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --with-inference) WITH_INFERENCE=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--workspace PATH] [--out PATH] [--with-inference]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

MEM="$WORKSPACE/memory"
OUT_DIR="${OUT_DIR:-$MEM/executive/reflections}"
mkdir -p "$OUT_DIR"

ISO=$(mktemp -d)
# Restore owner write before rm: isolation step may chmod a-w on snapshot files.
cleanup_iso() {
  chmod -R u+w "$ISO" 2>/dev/null || true
  rm -rf "$ISO" 2>/dev/null || true
}
trap cleanup_iso EXIT

# ── 1. Build isolated read-only snapshot of signals ──────────────────────────
mkdir -p "$ISO/memory"
# Copy only files that exist; never create live state as a side effect of copy
for rel in \
  pfc-state.json \
  executive-load.json \
  decision-queue.json \
  acc-state.json \
  acc-error-state.json \
  amygdala-state.json \
  vta-motivation.json \
  hippocampus-core.json \
  heartbeat-state.json
do
  if [ -f "$MEM/$rel" ]; then
    cp -a "$MEM/$rel" "$ISO/memory/$rel"
  fi
done

# Optional recent self notes (read-only)
if [ -d "$MEM/self" ]; then
  mkdir -p "$ISO/memory/self"
  # Cap to a few files to keep context small (KV-friendly)
  find "$MEM/self" -maxdepth 1 -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null \
    | head -n 8 | while read -r f; do
      cp -a "$f" "$ISO/memory/self/" 2>/dev/null || true
    done
fi

# Fingerprint live files we copied so we can prove no live mutation
LIVE_FINGERPRINT=$(
  {
    for f in "$ISO/memory"/*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      if [ -f "$MEM/$base" ]; then
        sha256sum "$MEM/$base"
      fi
    done
  } 2>/dev/null | sha256sum | awk '{print $1}'
)

# Harden isolation: analysis may only read
chmod -R a-w "$ISO" 2>/dev/null || true
# Temp still needs to be removable by us — keep ISO dir itself writable for trap
chmod u+w "$ISO" 2>/dev/null || true

# ── 2. Optional inference slot (still no live writes) ───────────────────────
if [ "$WITH_INFERENCE" -eq 1 ]; then
  # shellcheck source=/dev/null
  source "$ROOT/core/concurrency/semaphore.sh"
  # Background reflection must respect KV cap (hard 2048)
  if ! semaphore_check_kv_cap 2048; then
    echo "isolated-reflect: KV cap check failed" >&2
    exit 1
  fi
  if ! semaphore_acquire_inference; then
    echo "isolated-reflect: inference slot busy — falling back to offline" >&2
    WITH_INFERENCE=0
  else
    # Offline synthesis only in this phase; release immediately after "reservation"
    # (full LLM path is Phase 3 / spawn). Holding the slot documents the contract.
    semaphore_release_inference || true
    WITH_INFERENCE=0
  fi
fi

# ── 3. Offline synthesis from isolated tree only ─────────────────────────────
REFLECTION=$(ISO="$ISO" WORKSPACE_ISO="$ISO" python3 - <<'PY'
import json, os, hashlib
from pathlib import Path
from datetime import datetime, timezone

iso = Path(os.environ["ISO"])
mem = iso / "memory"

def load(name, default=None):
    p = mem / name
    if not p.is_file():
        return default
    try:
        return json.loads(p.read_text())
    except Exception:
        return default

pfc = load("pfc-state.json", {}) or {}
eload = load("executive-load.json", {}) or {}
queue = load("decision-queue.json", None)
acc = load("acc-state.json", {}) or {}
acc_err = load("acc-error-state.json", {}) or {}
amyg = load("amygdala-state.json", {}) or {}
vta = load("vta-motivation.json", {}) or {}

goals = pfc.get("goals") if isinstance(pfc, dict) else []
if not isinstance(goals, list):
    goals = []
active = [g for g in goals if isinstance(g, dict) and g.get("status") == "active"]
inhibitions = pfc.get("inhibitions") if isinstance(pfc, dict) else []
if not isinstance(inhibitions, list):
    inhibitions = []

if isinstance(queue, list):
    q_depth = len(queue)
elif isinstance(queue, dict):
    pending = queue.get("pending", queue.get("queue", []))
    q_depth = len(pending) if isinstance(pending, list) else 0
else:
    q_depth = 0

E = float(eload.get("E") or 0.0) if isinstance(eload, dict) else 0.0
band = (eload.get("band") if isinstance(eload, dict) else None) or "unknown"

# ACC conflicts
conflicts = []
if isinstance(acc, dict):
    raw = acc.get("conflicts") or acc.get("unresolved") or []
    if isinstance(raw, list):
        conflicts = [c for c in raw if isinstance(c, dict)]

# Error patterns
error_count = 0
if isinstance(acc_err, dict):
    errs = acc_err.get("errors") or acc_err.get("patterns") or acc_err.get("recent") or []
    if isinstance(errs, list):
        error_count = len(errs)
    else:
        error_count = int(acc_err.get("error_count") or 0)

mood = None
if isinstance(amyg, dict):
    mood = amyg.get("mood") or amyg.get("valence") or amyg.get("dominant_emotion")

drive = None
if isinstance(vta, dict):
    drive = vta.get("drive") or vta.get("motivation") or vta.get("level")

insights = []
candidate_goals = []

if len(active) == 0:
    insights.append("No active executive goals — system lacks directional priority.")
    candidate_goals.append({
        "description": "Establish and maintain clear active executive goals for the current work cycle",
        "priority": 0.7,
        "rationale": "Empty active-goal set increases idle drift and underutilizes arbitration",
        "source_signal": "pfc.goals.empty",
        "confidence": 0.85,
    })

if E >= 0.75:
    insights.append(f"Executive load high (E={E:.3f}, band={band}); load-reduction should defer non-essential inference.")
    candidate_goals.append({
        "description": "Complete or defer lowest-priority active goals to reduce executive load below 0.75",
        "priority": 0.8,
        "rationale": f"E={E:.3f} at/above hard ceiling",
        "source_signal": "executive_load.hard_ceiling",
        "confidence": 0.9,
    })
elif E < 0.35 and len(active) > 0:
    insights.append(f"Executive load underutilized (E={E:.3f}); capacity available for additional directed work.")
elif E < 0.35 and len(active) == 0:
    insights.append(f"Underutilized load with no goals (E={E:.3f}).")

if q_depth > 0:
    insights.append(f"Decision queue depth Q={q_depth}; pending decisions need clearance.")
    candidate_goals.append({
        "description": "Clear pending decision-queue items before accepting new open-ended work",
        "priority": min(0.9, 0.5 + 0.1 * q_depth),
        "rationale": f"Q={q_depth} inflates executive load via 0.12*Q",
        "source_signal": "decision_queue.pending",
        "confidence": 0.8,
    })

unresolved = [c for c in conflicts if c.get("status") in (None, "open", "unresolved", "active")]
if unresolved:
    insights.append(f"{len(unresolved)} unresolved ACC conflict(s) present.")
    desc = unresolved[0].get("description") or unresolved[0].get("summary") or "unresolved conflict"
    candidate_goals.append({
        "description": f"Resolve ACC conflict: {str(desc)[:120]}",
        "priority": 0.75,
        "rationale": "Unresolved conflicts degrade arbitration quality",
        "source_signal": "acc.conflicts",
        "confidence": 0.75,
    })

if error_count > 0:
    insights.append(f"ACC-error memory reports {error_count} error pattern(s)/entries.")
    candidate_goals.append({
        "description": "Review recent error patterns and apply the highest-confidence fix lesson",
        "priority": 0.7,
        "rationale": f"error_count={error_count}",
        "source_signal": "acc_error.patterns",
        "confidence": 0.7,
    })

if mood is not None:
    insights.append(f"Affective signal present (mood/valence={mood!r}).")
if drive is not None:
    insights.append(f"Motivational drive signal present (drive={drive!r}).")

if not insights:
    insights.append("No strong anomaly signals; maintain steady-state and prefer existing goals.")

# Dedupe candidate descriptions against active goals (token overlap)
active_descs = [str(g.get("description") or "").lower() for g in active]

def too_similar(desc: str) -> bool:
    tokens = set(desc.lower().split())
    if not tokens:
        return False
    for ad in active_descs:
        at = set(ad.split())
        if not at:
            continue
        overlap = len(tokens & at) / max(1, len(tokens))
        if overlap >= 0.6:
            return True
    return False

filtered = [c for c in candidate_goals if not too_similar(c["description"])]

# Stable proposal ids from content
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for i, c in enumerate(filtered):
    raw = f"{c['description']}|{c['source_signal']}|{now}"
    c["proposal_id"] = "goalprop_" + hashlib.sha256(raw.encode()).hexdigest()[:16]
    c["kind"] = "goal_proposal"
    c["status"] = "proposed"
    c["created_at"] = now

out = {
    "schema": 1,
    "kind": "isolated_reflection",
    "timestamp": now,
    "isolation": {
        "read_only": True,
        "write_permissions": False,
        "mode": "offline_heuristic",
        "snapshot_files": sorted([p.name for p in mem.glob("*") if p.is_file()]),
    },
    "signals": {
        "active_goal_count": len(active),
        "inhibition_count": len(inhibitions),
        "decision_queue_depth": q_depth,
        "executive_load_E": E,
        "executive_load_band": band,
        "unresolved_conflicts": len(unresolved),
        "error_count": error_count,
        "mood": mood,
        "drive": drive,
    },
    "insights": insights,
    "goal_proposals": filtered,
    "active_goal_ids": [g.get("id") for g in active if g.get("id")],
}
print(json.dumps(out, indent=2, sort_keys=True))
PY
)

# ── 4. Prove live WORKSPACE was not mutated by isolation step ────────────────
LIVE_FINGERPRINT_AFTER=$(
  {
    for f in "$ISO/memory"/*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      if [ -f "$MEM/$base" ]; then
        sha256sum "$MEM/$base"
      fi
    done
  } 2>/dev/null | sha256sum | awk '{print $1}'
)
if [ "$LIVE_FINGERPRINT" != "$LIVE_FINGERPRINT_AFTER" ]; then
  echo "isolated-reflect: FATAL live workspace mutated during isolated reflection" >&2
  exit 1
fi

TS=$(date -u +"%Y%m%dT%H%M%SZ")
OUT_FILE="$OUT_DIR/reflection_${TS}.json"
# OUT_DIR is outside ISO and writable
printf '%s\n' "$REFLECTION" > "$OUT_FILE"
# Also write latest pointer
printf '%s\n' "$REFLECTION" > "$OUT_DIR/latest.json"

# Provenance (orchestrator side — not inside isolated process)
if [ -x "$ROOT/core/provenance/log-provenance.sh" ]; then
  bash "$ROOT/core/provenance/log-provenance.sh" append \
    --proposal-id "reflect_${TS}" \
    --content "$OUT_FILE" \
    --parent-hash "null" \
    --proposer "isolated-reflect" \
    --reviewer "phase2-offline" \
    --rollback-status none >/dev/null || true
fi

echo "$OUT_FILE"
