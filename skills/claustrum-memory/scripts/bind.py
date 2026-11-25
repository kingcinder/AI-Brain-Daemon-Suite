#!/usr/bin/env python3
"""bind.py — the claustrum organ's binding pass.

Binds every organ state file's summary into memory/cortical.json
under the `binding` key (existing record content preserved whole —
the claustrum owns this record and drops nothing), detects
incoherence (an organ unread > 26h while the collective's median
consultation is < 2h; an unparseable state file), ledgers findings
in memory/binding-ledger.jsonl, and routes incoherence patterns to
the ACC error ledger.

Env: WORKSPACE. Exit 0 on a completed pass.
"""
import glob
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone

WS = os.environ.get("WORKSPACE") or os.path.expanduser("~/.juno-brain/workspace")
MEM = os.path.join(WS, "memory")
NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
PASS_ID = "bind_" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
EPOCH = time.time()
SKIP = {"claustrum-state.json", "cortical.json"}


def parse_ts(v):
    if isinstance(v, str) and v:
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except Exception:
            return None
    if isinstance(v, (int, float)) and v > 0:
        return float(v)
    return None


def main():
    organs = {}
    incoherences = []
    consult_ages = []
    for path in sorted(glob.glob(os.path.join(MEM, "*-state.json"))):
        name = os.path.basename(path)[:-len("-state.json")]
        if os.path.basename(path) in SKIP:
            continue
        try:
            d = json.load(open(path))
        except Exception as e:
            incoherences.append({"organ": name, "kind": "unparseable-state",
                                 "detail": str(e)[:120]})
            organs[name] = {"status": "unparseable"}
            continue
        consulted = parse_ts(d.get("lastConsultedAt"))
        updated = parse_ts(d.get("lastUpdated"))
        age_h = (EPOCH - consulted) / 3600.0 if consulted else None
        if age_h is not None:
            consult_ages.append(age_h)
        organs[name] = {
            "status": "bound",
            "lastConsultedAt": d.get("lastConsultedAt"),
            "lastUpdated": d.get("lastUpdated"),
            "consultAgeH": round(age_h, 2) if age_h is not None else None,
        }
    median_age = statistics.median(consult_ages) if consult_ages else None
    collective_active = median_age is not None and median_age < 2.0
    if collective_active:
        for name, o in organs.items():
            if o.get("consultAgeH") is not None and o["consultAgeH"] > 26.0:
                incoherences.append({
                    "organ": name, "kind": "unread-while-collective-active",
                    "detail": f"lastConsultedAt {o['consultAgeH']:.0f}h old; collective median {median_age:.1f}h"})

    # Bind into cortical.json, preserving the record's existing content.
    cortical_path = os.path.join(MEM, "cortical.json")
    cortical = {}
    if os.path.exists(cortical_path):
        try:
            cortical = json.load(open(cortical_path))
        except Exception:
            cortical = {}
    cortical["binding"] = {
        "boundAt": NOW,
        "passId": PASS_ID,
        "organCount": len(organs),
        "organs": organs,
        "coherence": {
            "collectiveMedianConsultAgeH": round(median_age, 2) if median_age is not None else None,
            "incoherences": incoherences,
        },
    }
    writer = os.path.join(WS, "core", "gate", "store_write.py")
    if os.path.exists(writer):
        with open("/tmp/.claustrum-record.json", "w") as f:
            json.dump(cortical, f)
        subprocess.run(["python3", writer, "write-record", "--store", cortical_path,
                        "--record", "/tmp/.claustrum-record.json",
                        "--writer", "claustrum-memory/bind.sh"],
                       env={**os.environ, "WORKSPACE": WS}, capture_output=True)
    else:
        with open(cortical_path, "w") as f:
            json.dump(cortical, f, indent=2)

    # Ledger + ACC routing for incoherences
    ledger_path = os.path.join(MEM, "binding-ledger.jsonl")
    acc_log = os.path.join(WS, "skills/acc-error-memory/scripts/log-error.sh")
    for inc in incoherences:
        entry = {"ts": NOW, "pass_id": PASS_ID, "action": "incoherence", **inc}
        if os.path.exists(writer):
            with open("/tmp/.claustrum-entry.json", "w") as f:
                json.dump(entry, f)
            subprocess.run(["python3", writer, "append-jsonl", "--store", ledger_path,
                            "--entry", "/tmp/.claustrum-entry.json",
                            "--writer", "claustrum-memory/bind.sh"],
                           env={**os.environ, "WORKSPACE": WS}, capture_output=True)
        else:
            with open(ledger_path, "a") as f:
                f.write(json.dumps(entry) + "\n")
        if os.path.exists(acc_log):
            subprocess.run(["bash", acc_log, "--pattern", "binding-incoherence",
                            "--context", f"claustrum {PASS_ID}: {inc['organ']} — {inc['kind']}: {inc.get('detail', '')}",
                            "--mitigation", "check the organ's reader in the helm-drain 2c list; binding re-tests next pass"],
                           env={**os.environ, "WORKSPACE": WS}, capture_output=True, timeout=30)

    state_path = os.path.join(MEM, "claustrum-state.json")
    state = {}
    if os.path.exists(state_path):
        try:
            state = json.load(open(state_path))
        except Exception:
            state = {}
    totals = state.get("totals", {})
    totals["bindings"] = totals.get("bindings", 0) + 1
    totals["incoherences"] = totals.get("incoherences", 0) + len(incoherences)
    state.update({
        "version": "1.0",
        "lastBoundAt": NOW,
        "lastUpdated": NOW,
        "totals": totals,
        "lastBinding": {"passId": PASS_ID, "organCount": len(organs),
                        "incoherences": incoherences},
    })
    state.setdefault("lastConsultedAt", None)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

    if incoherences:
        desc = "; ".join(f"{i['organ']}:{i['kind']}" for i in incoherences)
        print(f"🧩 Claustrum binding {PASS_ID}: {len(organs)} organs bound; {len(incoherences)} incoherence(s): {desc}")
    else:
        print(f"🧩 Claustrum binding {PASS_ID}: {len(organs)} organs bound; coherence OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
