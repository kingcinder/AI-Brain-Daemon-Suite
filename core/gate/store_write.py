#!/usr/bin/env python3
"""store_write.py — Shared conservation writer (Gated-Ingress Refactor,
Phase B, invariants I3 + I4, 2026-11-20).

All queue/state writes to registered stores go through this writer.
It implements append/merge semantics ONLY — overwrite is not offered.
Every write emits a receipt to memory/gate-receipts.jsonl:

  {ts, store, semantics, in_count, carried, added,
   discarded: [{key, reason}...], out_count, writer}

and the conservation identity  in = out + discarded  (for merges:
in = carried + added) must hold or the write ABORTS (exit 5) and the
store is left untouched.

Subcommands:

  merge-list --store PATH --list-field pending --key id --items FILE
      Load the existing JSON list store ({"<list-field>": [...]}),
      merge new items (JSON array in FILE, or "-" for stdin):
      existing items are carried in order; a new item whose key value
      already exists is discarded with reason "duplicate-key"; new
      items are appended with fresh keys untouched. Writes back the
      merged store atomically (tmp + rename, under the store's flock).

  append-jsonl --store PATH --items FILE
      Append JSON objects (array in FILE or "-") as JSONL lines.
      Receipt counts lines before/after.

  write-record --store PATH --record FILE [--require-baseline]
      Write a single judged record (deploy record, evaluation, ...).
      With --require-baseline (I4): the record MUST carry a non-null
      "baseline_metrics" object and a "provenance" field, or the write
      is rejected at write time (exit 6) — a monitor can never again
      compare against a silent default.

Exit codes: 0 ok · 2 usage · 5 conservation abort · 6 provenance reject.
"""
import fcntl
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from envelope import workspace  # noqa: E402
except Exception:
    # Standalone copy (sandbox/fixture trees that carry the writer
    # without its sibling): resolve the workspace locally, same rules.
    def workspace():
        return (os.environ.get("BRAIN_WORKSPACE")
                or os.environ.get("WORKSPACE")
                or os.path.expanduser("~/.juno-brain/workspace"))


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit_receipt(ws, receipt):
    path = os.path.join(ws, "memory", "gate-receipts.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(receipt, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())


def load_items(argv_items):
    if argv_items == "-":
        raw = sys.stdin.read()
    else:
        with open(argv_items) as f:
            raw = f.read()
    data = json.loads(raw)
    if isinstance(data, dict):
        return [data]
    return list(data)


def parse_args(argv, spec):
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in spec and spec[a]:
            out[a.lstrip("-").replace("-", "_")] = argv[i + 1]
            i += 2
        elif a in spec:
            out[a.lstrip("-").replace("-", "_")] = True
            i += 1
        else:
            i += 1
    return out


def cmd_merge_list(argv):
    args = parse_args(argv, {"--store": 1, "--list-field": 1, "--key": 1,
                             "--items": 1, "--writer": 1})
    store = args["store"]
    field = args.get("list_field", "pending")
    key = args.get("key", "id")
    ws = workspace()

    lock_path = store + ".lock"
    lock_f = open(lock_path, "a")
    fcntl.flock(lock_f, fcntl.LOCK_EX)
    try:
        existing = []
        if os.path.exists(store):
            with open(store) as f:
                doc = json.load(f)
            existing = doc.get(field, []) or []
        else:
            doc = {}
        new_items = load_items(args["items"])

        seen = {}
        for it in existing:
            if isinstance(it, dict) and key in it:
                seen[it[key]] = True
        carried = len(existing)
        added_items, discarded = [], []
        for it in new_items:
            k = it.get(key) if isinstance(it, dict) else None
            if k is not None and k in seen:
                discarded.append({"key": k, "reason": "duplicate-key"})
                continue
            if k is not None:
                seen[k] = True
            added_items.append(it)
        merged = existing + added_items

        in_count = carried + len(new_items)
        out_count = len(merged)
        if in_count != out_count + len(discarded):
            print(json.dumps({"aborted": True,
                              "reason": "conservation identity violated",
                              "in": in_count, "out": out_count,
                              "discarded": len(discarded)}), file=sys.stderr)
            return 5

        doc[field] = merged
        doc.setdefault("created", now_iso()[:10])
        tmp = store + ".tmp.gate"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, store)

        receipt = {"ts": now_iso(), "store": store, "semantics": "merge",
                   "in_count": in_count, "carried": carried,
                   "added": len(added_items), "discarded": discarded,
                   "out_count": out_count,
                   "writer": args.get("writer", "store_write.py")}
        emit_receipt(ws, receipt)
        print(json.dumps(receipt))
        return 0
    finally:
        fcntl.flock(lock_f, fcntl.LOCK_UN)
        lock_f.close()


def cmd_append_jsonl(argv):
    args = parse_args(argv, {"--store": 1, "--entry": 1, "--writer": 1})
    store = args["store"]
    ws = workspace()
    before = 0
    if os.path.exists(store):
        with open(store, "rb") as f:
            before = sum(1 for _ in f)
    items = load_items(args["entry"])
    with open(store, "a") as f:
        for it in items:
            f.write(json.dumps(it, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())
    receipt = {"ts": now_iso(), "store": store, "semantics": "append",
               "in_count": before + len(items), "carried": before,
               "added": len(items), "discarded": [],
               "out_count": before + len(items),
               "writer": args.get("writer", "store_write.py")}
    emit_receipt(ws, receipt)
    print(json.dumps(receipt))
    return 0


def cmd_write_record(argv):
    args = parse_args(argv, {"--store": 1, "--record": 1, "--writer": 1,
                             "--require-baseline": 0})
    store = args["store"]
    ws = workspace()
    with open(args["record"]) as f:
        record = json.load(f)
    if args.get("require_baseline"):
        problems = []
        if not isinstance(record.get("baseline_metrics"), dict):
            problems.append("baseline_metrics missing or not an object (I4)")
        if not record.get("provenance"):
            problems.append("provenance missing (I4)")
        if problems:
            print(json.dumps({"rejected": True, "reasons": problems}),
                  file=sys.stderr)
            return 6
    tmp = store + ".tmp.gate"
    with open(tmp, "w") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, store)
    receipt = {"ts": now_iso(), "store": store, "semantics": "merge",
               "in_count": 1, "carried": 0, "added": 1, "discarded": [],
               "out_count": 1, "writer": args.get("writer", "store_write.py")}
    emit_receipt(ws, receipt)
    print(json.dumps(receipt))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    cmd = sys.argv[1]
    fn = {"merge-list": cmd_merge_list, "append-jsonl": cmd_append_jsonl,
          "write-record": cmd_write_record}.get(cmd)
    if fn is None:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(fn(sys.argv[2:]))
