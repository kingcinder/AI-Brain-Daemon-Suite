#!/usr/bin/env python3
"""envelope.py — Gated ingress for Juno's brain harness (Gated-Ingress
Refactor, Phase B, 2026-11-20).

Every information unit that enters Juno's substrate — external stimulus,
organ output, Juno's own reasoning products, scheduled-job output, and
outputs of gates above the substrate (approvals, refusals, tool results)
at the moment they land here — enters as a signal ENVELOPE through the
thalamic gate. No side channels.

Mandatory envelope fields (gate rejects any unit missing one):
  signal_id   unique id for this unit
  origin      external | organ | juno | job | supra
  source_id   who/what produced it (skill name, job name, "juno", ...)
  ts          ISO-8601 UTC timestamp
  type        unit type (e.g. "signal", "proposal.defect-fix", "ask")
  urgency     routine | elevated | critical
  destination a REGISTERED flow id from core/gate/flows.json, or one of
              the built-in queue destinations: helm-queue, brain-signals
  provenance  non-empty object: {parents: [...]} and/or
              {evidence: [...]} — ids/refs this unit derives from
  payload_ref reference to the payload (path, queue id, or inline key)

Subcommands:
  validate  read envelope JSON (file arg or stdin); print OK/rejection.
            Exit 0 valid, 3 rejected (reasons on stderr as JSON).
  ingress   validate, then route:
              - append the envelope to memory/brain-signals.jsonl
              - if urgency == critical and destination == helm-queue:
                also enqueue a decision task into the helm queue via
                the openclaw shim (juno:enqueue)
            Prints a receipt JSON. Exit 3 on rejection (nothing routed).

Workspace resolution mirrors the openclaw shim: $BRAIN_WORKSPACE, else
$WORKSPACE, else $OPENCLAW_WORKSPACE, else ~/.juno-brain/workspace.
"""
import json
import os
import subprocess
import sys

MANDATORY = ["signal_id", "origin", "source_id", "ts", "type",
             "urgency", "destination", "provenance", "payload_ref"]
ORIGINS = {"external", "organ", "juno", "job", "supra"}
URGENCIES = {"routine", "elevated", "critical"}
BUILTIN_DESTINATIONS = {"helm-queue", "brain-signals"}


def workspace():
    for var in ("BRAIN_WORKSPACE", "WORKSPACE", "OPENCLAW_WORKSPACE"):
        val = os.environ.get(var)
        if val:
            return val
    return os.path.expanduser("~/.juno-brain/workspace")


def registry_destinations(ws):
    """Registered flow ids from core/gate/flows.json (empty set if absent)."""
    path = os.path.join(ws, "core", "gate", "flows.json")
    try:
        with open(path) as f:
            reg = json.load(f)
        return {fl["id"] for fl in reg.get("flows", []) if "id" in fl}
    except Exception:
        return set()


def validate(env, ws):
    """Return list of rejection reasons ([] = valid)."""
    reasons = []
    if not isinstance(env, dict):
        return ["envelope is not a JSON object"]
    for field in MANDATORY:
        if field not in env or env[field] in (None, ""):
            reasons.append(f"missing mandatory field: {field}")
    if reasons:
        return reasons
    if env["origin"] not in ORIGINS:
        reasons.append(f"origin not in {sorted(ORIGINS)}: {env['origin']!r}")
    if env["urgency"] not in URGENCIES:
        reasons.append(f"urgency not in {sorted(URGENCIES)}: {env['urgency']!r}")
    prov = env["provenance"]
    if not isinstance(prov, dict):
        reasons.append("provenance must be an object {parents|evidence}")
    else:
        parents = prov.get("parents") or []
        evidence = prov.get("evidence") or []
        if not parents and not evidence:
            reasons.append("provenance empty: needs parents and/or evidence refs")
    dest = env["destination"]
    if dest not in BUILTIN_DESTINATIONS and dest not in registry_destinations(ws):
        reasons.append(f"destination not registered in flows.json: {dest!r}")
    return reasons


def load_envelope(argv):
    if len(argv) > 1 and argv[1] not in ("-",):
        with open(argv[1]) as f:
            return json.load(f)
    return json.load(sys.stdin)


def cmd_validate(argv):
    ws = workspace()
    try:
        env = load_envelope(argv)
    except Exception as e:
        print(json.dumps({"rejected": True, "reasons": [f"unparseable: {e}"]}),
              file=sys.stderr)
        return 3
    reasons = validate(env, ws)
    if reasons:
        print(json.dumps({"rejected": True, "reasons": reasons}), file=sys.stderr)
        return 3
    print(json.dumps({"valid": True, "signal_id": env["signal_id"],
                      "destination": env["destination"],
                      "urgency": env["urgency"]}))
    return 0


def cmd_ingress(argv):
    ws = workspace()
    try:
        env = load_envelope(argv)
    except Exception as e:
        print(json.dumps({"rejected": True, "reasons": [f"unparseable: {e}"]}),
              file=sys.stderr)
        return 3
    reasons = validate(env, ws)
    if reasons:
        print(json.dumps({"rejected": True, "reasons": reasons}), file=sys.stderr)
        return 3

    receipt = {"signal_id": env["signal_id"], "routed": []}

    # Route 1: the signal bus (gate --process consumes from its checkpoint).
    bus = os.path.join(ws, "memory", "brain-signals.jsonl")
    with open(bus, "a") as f:
        f.write(json.dumps({"envelope": env}, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())
    receipt["routed"].append("brain-signals")

    # Route 2 (I5): critical units bound for Juno's decision queue go to
    # the helm queue NOW (15-min rhythm), never to a weekly batch.
    if env["urgency"] == "critical" and env["destination"] == "helm-queue":
        req = {
            "system": "gated-ingress: critical envelope routed by the thalamic gate",
            "user": (f"CRITICAL envelope {env['signal_id']} "
                     f"(type {env['type']}, origin {env['origin']}, "
                     f"source {env['source_id']}): payload_ref={env['payload_ref']}. "
                     f"Decide and act on this now; it bypassed batch routing "
                     f"under invariant I5."),
            "json": False,
        }
        shim = os.path.expanduser("~/.local/bin/openclaw")
        env_vars = dict(os.environ, BRAIN_WORKSPACE=ws)
        try:
            out = subprocess.run([shim, "juno:enqueue"], input=json.dumps(req),
                                 capture_output=True, text=True, env=env_vars,
                                 timeout=30)
        except subprocess.TimeoutExpired:
            print(json.dumps({"rejected": True,
                              "reasons": ["helm enqueue timed out (30s)"]}),
                  file=sys.stderr)
            return 4
        if out.returncode != 0:
            print(json.dumps({"rejected": True,
                              "reasons": [f"helm enqueue failed: {out.stderr.strip()}"]}),
                  file=sys.stderr)
            return 4
        receipt["routed"].append("helm-queue")
        receipt["helm_task_id"] = out.stdout.strip()

    print(json.dumps(receipt))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("validate", "ingress"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    fn = cmd_validate if sys.argv[1] == "validate" else cmd_ingress
    sys.exit(fn(sys.argv[1:]))
