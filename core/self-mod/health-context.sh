#!/bin/bash
# health-context.sh — ROADMAP M5: brain-health context for outcome-driven proposals.
#
# Gathers the suite's current health signals into ONE compact JSON block so the
# self-mod proposal generator targets what is ACTUALLY breaking instead of a
# rotating preference list:
#
#   daemon_streaks      jobs with consecutive_failures >= 1 + last error
#                       (deep-brain-kernel-state.json → jobStats)
#   verification        most recent sweep from verification-report.jsonl:
#                       ts, filter, failed count, per-module failure list
#   acc_lessons         resolved error patterns with mitigation/insight
#                       (acc-state.json → resolved, via the same shape
#                        get-lessons.sh surfaces)
#   acc_calibration     flag→error calibration (acc-calibration.sh): how
#                       often anterior-cingulate conflict flags predict an
#                       actual acc-error correction within the window
#   graduation          review_mode / clean_streak / target (deferral state)
#   proposal_store      queued / rejected / deployed counts
#
# Any missing or unparseable source degrades to empty/zero — never fails the
# pipeline. Emits exactly one JSON object on stdout.
#
# Usage:
#   health-context.sh [--workspace PATH]
#
# Env:
#   WORKSPACE   defaults to $HOME/.hermes/workspace

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

MEM="$WORKSPACE/memory"

# ── 6. ACC flag→error calibration (own script, beside this one) ─────────────
ACC_CAL_JSON=""
if [ -x "$SELF_DIR/acc-calibration.sh" ]; then
  ACC_CAL_JSON=$(WORKSPACE="$WORKSPACE" bash "$SELF_DIR/acc-calibration.sh" 2>/dev/null) || ACC_CAL_JSON=""
fi

python3 - "$MEM" "$ACC_CAL_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

mem = Path(sys.argv[1])


def load(rel, default):
    try:
        return json.loads((mem / rel).read_text())
    except (OSError, ValueError, TypeError):
        return default


# ── 1. daemon failure streaks ───────────────────────────────────────────────
state = load("deep-brain-kernel-state.json", {})
stats = state.get("jobStats") or {}
streaks = []
for name, s in sorted(stats.items()):
    s = s or {}
    cf = int(s.get("consecutive_failures") or 0)
    if cf >= 1:
        streaks.append({
            "job": name,
            "consecutive_failures": cf,
            "last_error": s.get("last_error"),
            "last_failure_utc": s.get("last_failure_utc"),
        })

# ── 2. verification sweep (most recent line, failures surfaced) ─────────────
verification = {"ts": None, "filter": None, "failed": 0, "failures": []}
report_path = mem / "verification-report.jsonl"
if report_path.is_file():
    lines = [ln for ln in report_path.read_text(errors="replace").splitlines() if ln.strip()]
    if lines:
        try:
            latest = json.loads(lines[-1])
        except ValueError:
            latest = {}
        verification = {
            "ts": latest.get("ts"),
            "filter": latest.get("filter"),
            "failed": int((latest.get("totals") or {}).get("failed") or 0),
            "failures": latest.get("failures") or [],
        }

# ── 3. ACC lessons (resolved patterns) ──────────────────────────────────────
acc = load("acc-state.json", {})
resolved = acc.get("resolved") or {}
lessons = []
for name, d in sorted(resolved.items())[:10]:
    d = d or {}
    lesson = d.get("lesson") or {}
    lessons.append({
        "pattern": name,
        "count": int(d.get("count") or 0),
        "days_clear": int(d.get("daysClear") or 0),
        "mitigation": lesson.get("mitigation"),
        "insight": lesson.get("insight"),
    })

# ── 4. graduation / deferral state ──────────────────────────────────────────
grad = load("self-mod/graduation-streak.json", {})
streak = int(grad.get("clean_streak") or 0)
target = int(grad.get("clean_streak_target") or 20)
graduation = {
    "review_mode": "relaxed_review" if streak >= target else "full_review",
    "clean_streak": streak,
    "clean_streak_target": target,
    "remaining_to_graduate": max(0, target - streak),
}

# ── 5. proposal store counts ────────────────────────────────────────────────
queued = rejected = deployed = 0
props_dir = mem / "self-mod" / "proposals"
if props_dir.is_dir():
    for p in props_dir.glob("*.json"):
        if p.name == "index.jsonl":
            continue
        try:
            status = json.loads(p.read_text()).get("status")
        except (OSError, ValueError):
            continue
        if status == "queued":
            queued += 1
        elif status == "rejected":
            rejected += 1
        elif status == "deployed":
            deployed += 1

# ── 6. ACC calibration (parsed from the companion script's JSON; corrupt or
#        absent output degrades to zeros — never fails the block) ────────────
acc_cal = {
    "total_conflicts": 0, "flags_followed_by_error": 0, "hit_rate": 0.0,
    "false_positive_rate": 0.0, "total_errors": 0, "errors_unpredicted": 0,
    "by_type": {}, "window_days": 7,
}
try:
    if sys.argv[2]:
        acc_cal.update(json.loads(sys.argv[2]))
except (ValueError, TypeError):
    pass

out = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "daemon_streaks": streaks,
    "verification": verification,
    "acc_lessons": lessons,
    "acc_calibration": acc_cal,
    "graduation": graduation,
    "proposal_store": {"queued": queued, "rejected": rejected, "deployed": deployed},
}
print(json.dumps(out, indent=2))
PY
