#!/usr/bin/env python3
"""clearance-sweep.py — the glymphatic organ's duty (Gated-Ingress
Refactor, Amendment 3 creation, 2026-11-20).

One sweep:
  1. Backlog-age audit of every registered merge-semantics queue
     store: count + oldest entry age. Overstay (> OVERSTAY_HOURS)
     ESCALATES (ledger + ACC pattern + gate envelope) — another
     organ's queued material is never taken or deleted.
  2. Deadletter review: entries older than DEADLETTER_DAYS are
     archived to memory/clearance-archive/<date>/ (moved, ledgered).
  3. Stale gate leases reaped (dead pid / boot change / start-time
     mismatch), ledgered.
  4. Orphan top-level stores (absent from the flow registry) are
     reported (ledger + ACC), never deleted.

Conservation: every item found is accounted as archived, reaped,
escalated, reported, or retained; the identity is printed and stored
in glymphatic-state.json. Every action lands in
memory/clearance-ledger.jsonl with provenance.

Env: WORKSPACE (default ~/.juno-brain/workspace),
GLYMPHATIC_QUEUE_DIR (default ~/.openclaw/queue),
GLYMPHATIC_OVERSTAY_HOURS (default 48),
GLYMPHATIC_DEADLETTER_DAYS (default 7).
Exit 0 on a completed sweep (findings are data, not failure);
exit 2 on infrastructure failure (registry unreadable).
"""
import fnmatch
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

WS = os.environ.get("WORKSPACE") or os.path.expanduser("~/.juno-brain/workspace")
MEM = os.path.join(WS, "memory")
QUEUE_DIR = os.environ.get("GLYMPHATIC_QUEUE_DIR") or os.path.expanduser("~/.openclaw/queue")
OVERSTAY_H = float(os.environ.get("GLYMPHATIC_OVERSTAY_HOURS", "48"))
DEADLETTER_DAYS = float(os.environ.get("GLYMPHATIC_DEADLETTER_DAYS", "7"))
NOW = time.time()
SWEEP_ID = "sweep_" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

ledger = []
counts = {"found": 0, "archived": 0, "reaped": 0, "escalated": 0,
          "reported": 0, "retained": 0}
notes = []


def record(action, **fields):
    entry = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "sweep_id": SWEEP_ID, "action": action}
    entry.update(fields)
    ledger.append(entry)


def entry_age_h(entry):
    for key in ("timestamp", "ts", "created", "created_at", "detected_at"):
        v = entry.get(key)
        if isinstance(v, (int, float)) and v > 0:
            return (NOW - float(v)) / 3600.0
        if isinstance(v, str) and v:
            try:
                ts = datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
                return (NOW - ts) / 3600.0
            except Exception:
                continue
    return None


def main():
    reg_path = os.path.join(WS, "core", "gate", "flows.json")
    try:
        reg = json.load(open(reg_path))
    except Exception as e:
        print(f"clearance-sweep: registry unreadable: {e}", file=sys.stderr)
        return 2
    flows = reg.get("flows", [])
    internal_pats = reg.get("internal_stores", [])

    # ── 1. Backlog-age audit ────────────────────────────────────────
    for flow in flows:
        store = flow.get("store", "")
        if flow.get("semantics") != "merge" or not store.startswith("memory/pending-"):
            continue
        path = os.path.join(WS, store)
        if not os.path.exists(path):
            continue
        try:
            data = json.load(open(path))
        except Exception:
            continue
        entries = []
        if isinstance(data, list):
            entries = data
        elif isinstance(data, dict):
            for key in ("pending", "items", "entries"):
                if isinstance(data.get(key), list):
                    entries = data[key]
                    break
        if not entries:
            continue
        counts["found"] += len(entries)
        ages = [a for a in (entry_age_h(e) for e in entries if isinstance(e, dict))
                if a is not None]
        oldest = max(ages) if ages else None
        if oldest is not None and oldest > OVERSTAY_H:
            counts["escalated"] += 1
            counts["retained"] += len(entries) - 1
            record("escalate-overstay", store=store, flow=flow["id"],
                   entries=len(entries), oldest_age_h=round(oldest, 1),
                   disposition="escalated to owning organ + ACC; material retained in place")
            notes.append(f"overstay: {store} — {len(entries)} entries, oldest {oldest:.0f}h")
        else:
            counts["retained"] += len(entries)

    # ── 2. Deadletter review ────────────────────────────────────────
    dl_dir = os.path.join(QUEUE_DIR, "deadletter")
    archive_dir = os.path.join(MEM, "clearance-archive",
                               datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    if os.path.isdir(dl_dir):
        for path in sorted(glob.glob(os.path.join(dl_dir, "*.json"))):
            counts["found"] += 1
            age_h = (NOW - os.path.getmtime(path)) / 3600.0
            if age_h > DEADLETTER_DAYS * 24:
                os.makedirs(archive_dir, exist_ok=True)
                dest = os.path.join(archive_dir, os.path.basename(path))
                shutil.move(path, dest)
                counts["archived"] += 1
                record("archive-deadletter", file=os.path.basename(path),
                       age_h=round(age_h, 1), archived_to=os.path.relpath(dest, WS))
                notes.append(f"archived dead letter {os.path.basename(path)} ({age_h/24:.0f}d old)")
            else:
                counts["retained"] += 1

    # ── 3. Stale gate leases ────────────────────────────────────────
    boot_id = None
    try:
        boot_id = open("/proc/sys/kernel/random/boot_id").read().strip()
    except Exception:
        pass
    leases_dir = os.path.join(MEM, "gate-leases")
    if os.path.isdir(leases_dir):
        for path in sorted(glob.glob(os.path.join(leases_dir, "*.json"))):
            counts["found"] += 1
            try:
                lease = json.load(open(path))
            except Exception:
                counts["retained"] += 1
                continue
            pid = lease.get("pid")
            stale, why = False, ""
            if boot_id and lease.get("boot_id") and lease["boot_id"] != boot_id:
                stale, why = True, "boot-id changed"
            elif not isinstance(pid, int) or pid <= 0:
                stale, why = True, "no live pid recorded"
            else:
                try:
                    os.kill(pid, 0)
                except (ProcessLookupError, PermissionError):
                    stale, why = True, "holder pid dead"
                except Exception:
                    pass
                if not stale and lease.get("proc_start"):
                    try:
                        stat = open(f"/proc/{pid}/stat").read()
                        start = int(stat.rsplit(")", 1)[1].split()[19])
                        # lease.sh records proc_start as a STRING (jq
                        # --arg); compare string-to-string or every
                        # live lease looks "reused". (First live sweep
                        # reaped the real daemon/keeper leases on this
                        # bug; fixed 2026-11-20, leases re-acquired via
                        # sanctioned service restart.)
                        if str(start) != str(lease["proc_start"]):
                            stale, why = True, "pid reused (start-time mismatch)"
                    except Exception:
                        pass
            if stale:
                os.unlink(path)
                counts["reaped"] += 1
                record("reap-lease", name=lease.get("name"), holder_pid=pid, reason=why)
                notes.append(f"reaped stale lease {lease.get('name')} ({why})")
            else:
                counts["retained"] += 1

    # ── 4. Orphan stores ────────────────────────────────────────────
    def covered(relpath, basename):
        for f in flows:
            s = f.get("store", "")
            if s == relpath or (s and relpath.startswith(s.rstrip("/") + "/")):
                return True
        return any(fnmatch.fnmatch(basename, p) or fnmatch.fnmatch(relpath, p)
                   or (p.endswith("/") and relpath.startswith(p))
                   for p in internal_pats)

    for path in sorted(glob.glob(os.path.join(MEM, "*.json")) +
                       glob.glob(os.path.join(MEM, "*.jsonl"))):
        base = os.path.basename(path)
        rel = os.path.join("memory", base)
        if base in ("clearance-ledger.jsonl", "glymphatic-state.json"):
            continue  # this organ's own stores, registered with this build
        if not covered(rel, base):
            counts["found"] += 1
            counts["reported"] += 1
            record("report-orphan", store=rel,
                   disposition="reported to ACC; never deleted by clearance")
            notes.append(f"orphan store reported: {rel}")

    # ── Ledger + state ──────────────────────────────────────────────
    if ledger:
        writer = os.path.join(WS, "core", "gate", "store_write.py")
        ledger_path = os.path.join(MEM, "clearance-ledger.jsonl")
        if os.path.exists(writer):
            for entry in ledger:
                with open("/tmp/.glymphatic-entry.json", "w") as f:
                    json.dump(entry, f)
                subprocess.run(["python3", writer, "append-jsonl",
                                "--store", ledger_path,
                                "--entry", "/tmp/.glymphatic-entry.json",
                                "--writer", "glymphatic-memory/clearance-sweep.sh"],
                               env={**os.environ, "WORKSPACE": WS},
                               capture_output=True)
        else:
            with open(ledger_path, "a") as f:
                for entry in ledger:
                    f.write(json.dumps(entry) + "\n")

    state_path = os.path.join(MEM, "glymphatic-state.json")
    state = {}
    if os.path.exists(state_path):
        try:
            state = json.load(open(state_path))
        except Exception:
            state = {}
    totals = state.get("totals", {})
    totals["sweeps"] = totals.get("sweeps", 0) + 1
    totals["archived"] = totals.get("archived", 0) + counts["archived"]
    totals["reaped"] = totals.get("reaped", 0) + counts["reaped"]
    totals["escalated"] = totals.get("escalated", 0) + counts["escalated"]
    totals["orphansReported"] = totals.get("orphansReported", 0) + counts["reported"]
    state.update({
        "version": "1.0",
        "lastSweepAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lastUpdated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "totals": totals,
        "lastSweep": {**counts, "notes": notes[:12], "sweep_id": SWEEP_ID},
    })
    state.setdefault("lastConsultedAt", None)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

    # Escalations reach the ACC through its own error log (its duty:
    # the verdict), and enter the signal stream through the gate.
    acc_log = os.path.join(WS, "skills/acc-error-memory/scripts/log-error.sh")
    gate = os.path.join(WS, "core", "gate", "envelope.py")
    for entry in ledger:
        if entry["action"] == "escalate-overstay" and os.path.exists(acc_log):
            subprocess.run(["bash", acc_log, "--pattern", "clearance-overstay",
                            "--context", f"{entry['store']}: {entry['entries']} entries, oldest {entry['oldest_age_h']}h (glymphatic sweep {SWEEP_ID})",
                            "--mitigation", "owning organ to consume or consciously retain its backlog; glymphatic re-audits next sweep"],
                           env={**os.environ, "WORKSPACE": WS},
                           capture_output=True, timeout=30)
        if entry["action"] in ("escalate-overstay", "report-orphan") and os.path.exists(gate):
            env_obj = {
                "signal_id": f"{SWEEP_ID}_{entry['action']}_{abs(hash(json.dumps(entry, sort_keys=True))) % 99999}",
                "origin": "organ", "source_id": "glymphatic-memory",
                "ts": entry["ts"], "type": f"clearance.{entry['action']}",
                "urgency": "elevated", "destination": "brain-signals",
                "provenance": {"parents": [SWEEP_ID], "evidence": ["memory/clearance-ledger.jsonl"]},
                "payload_ref": entry.get("store", entry.get("file", "")),
            }
            with open("/tmp/.glymphatic-env.json", "w") as f:
                json.dump(env_obj, f)
            subprocess.run(["python3", gate, "ingress", "/tmp/.glymphatic-env.json"],
                           env={**os.environ, "WORKSPACE": WS},
                           capture_output=True, timeout=30)

    accounted = (counts["archived"] + counts["reaped"] + counts["escalated"]
                 + counts["reported"] + counts["retained"])
    # Item-level identity: every found item is accounted exactly once
    # (an escalated store accounts its oldest entry as the escalated
    # item and the rest as retained-in-place).
    identity = "OK" if accounted == counts["found"] else \
        f"VIOLATED (found {counts['found']} != accounted {accounted})"
    state["lastSweep"]["conservation"] = identity
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)
    print(f"🌊 Glymphatic sweep {SWEEP_ID}: found {counts['found']} items; "
          f"archived {counts['archived']}, reaped {counts['reaped']}, "
          f"escalated {counts['escalated']} stores, reported {counts['reported']}, "
          f"retained {counts['retained']} — conservation: {identity}")
    for n in notes[:8]:
        print(f"   - {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
