#!/bin/bash
# Unit: ROADMAP M7 autonomy contract — compute_autonomy_mode() + print_autonomy()
# derive auto_mode vs steward_mode from evidence (graduation streak, unhealthy
# jobs, auto-rollbacks in window) and persist autonomy-state.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE; WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
mkdir -p "$WORKSPACE/memory/self-mod/deploys" "$WORKSPACE/skills"

# Import the kernel module against this temp workspace.
python3 - "$WORKSPACE" "$ROOT/deep-brain-kernel.py" << 'PY'
import importlib.util, json, os, sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

ws = Path(sys.argv[1])
os.environ["WORKSPACE"] = str(ws)
spec = importlib.util.spec_from_file_location("dbk", sys.argv[2])
dbk = importlib.util.module_from_spec(spec)
sys.modules["dbk"] = dbk
spec.loader.exec_module(dbk)

def write(rel, obj):
    p = ws / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj) if not isinstance(obj, str) else obj + "\n")

def seed_daemon(streaks):
    stats = {}
    for name, cf in streaks.items():
        stats[name] = {"success": 1, "failure": cf, "consecutive_failures": cf}
    write("memory/deep-brain-kernel-state.json", {"lastTickUtc": "2026-08-08T00:00:00Z", "jobStats": stats})

# ── Case 1: graduated + healthy + no rollbacks → auto_mode ──────────────────
write("memory/self-mod/graduation-streak.json", {
    "clean_streak": 20, "clean_streak_target": 20, "review_mode": "relaxed_review"})
seed_daemon({})
m = dbk.compute_autonomy_mode(dbk.DaemonState(dbk.DAEMON_STATE_FILE))
assert m["mode"] == "auto_mode" and m["auto"] is True, f"case1: {m}"
assert m["evidence"]["graduated"] is True and m["evidence"]["unhealthy_jobs"] == 0, f"case1 ev: {m}"
print("case1 auto_mode: ok")

# ── Case 2: unhealthy job (streak >= 3) → steward_mode ──────────────────────
seed_daemon({"verification_pass": 3})
m = dbk.compute_autonomy_mode(dbk.DaemonState(dbk.DAEMON_STATE_FILE))
assert m["mode"] == "steward_mode" and m["auto"] is False, f"case2: {m}"
assert m["evidence"]["unhealthy_jobs"] == 1, f"case2 ev: {m}"
print("case2 unhealthy → steward_mode: ok")

# ── Case 3: not graduated (streak < target) → steward_mode ──────────────────
write("memory/self-mod/graduation-streak.json", {
    "clean_streak": 5, "clean_streak_target": 20, "review_mode": "full_review"})
seed_daemon({})
m = dbk.compute_autonomy_mode(dbk.DaemonState(dbk.DAEMON_STATE_FILE))
assert m["mode"] == "steward_mode", f"case3: {m}"
print("case3 not graduated → steward_mode: ok")

# ── Case 4: graduated + healthy but rollbacks over cap → steward_mode ───────
write("memory/self-mod/graduation-streak.json", {
    "clean_streak": 25, "clean_streak_target": 20, "review_mode": "relaxed_review"})
seed_daemon({})
now = datetime.now(timezone.utc)
for i in range(4):
    write(f"memory/self-mod/deploys/rb{i}.json", {
        "proposal_id": f"rb{i}", "rolled_back": True,
        "rollback_at": (now - timedelta(days=i)).isoformat().replace("+00:00", "Z")})
m = dbk.compute_autonomy_mode(dbk.DaemonState(dbk.DAEMON_STATE_FILE),
                              window_days=30, max_auto_rollbacks=3)
assert m["mode"] == "steward_mode", f"case4: {m}"
assert m["evidence"]["auto_rollbacks_in_window"] == 4, f"case4 ev: {m}"
print("case4 rollback cap → steward_mode: ok")

# ── Case 5: old rollbacks outside window don't count → auto_mode ────────────
import os as _os
for f in (ws / "memory/self-mod/deploys").glob("rb*.json"):
    f.unlink()
write("memory/self-mod/deploys/old.json", {
    "proposal_id": "old", "rolled_back": True,
    "rollback_at": (now - timedelta(days=60)).isoformat().replace("+00:00", "Z")})
m = dbk.compute_autonomy_mode(dbk.DaemonState(dbk.DAEMON_STATE_FILE),
                              window_days=30, max_auto_rollbacks=3)
assert m["mode"] == "auto_mode", f"case5: {m}"
assert m["evidence"]["auto_rollbacks_in_window"] == 0, f"case5 ev: {m}"
print("case5 window excludes old rollbacks: ok")

# ── print_autonomy persists autonomy-state.json + correct exit code ─────────
write("memory/self-mod/graduation-streak.json", {
    "clean_streak": 25, "clean_streak_target": 20, "review_mode": "relaxed_review"})
for f in (ws / "memory/self-mod/deploys").glob("*.json"):
    f.unlink()
rc = dbk.print_autonomy()
assert rc == 0, f"print_autonomy auto_mode rc: {rc}"
astate = json.loads((ws / "memory/self-mod/autonomy-state.json").read_text())
assert astate["mode"] == "auto_mode" and astate["auto"] is True, f"persisted: {astate}"
assert astate.get("computed_at"), "computed_at present"
print("print_autonomy persists autonomy-state.json (auto_mode rc=0): ok")

print("PASS: autonomy-report")
PY
