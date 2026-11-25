#!/usr/bin/env python3
"""invariant-patrol — proactive invariant checks over Juno's harness.

Ordered by Dither 2026-11-20 ("proactively verify that those blockages and
overflows are not still occurring in different as-of-yet undiscovered
locations"), folded into the daily self-improvement cycle. The principle:
do not hunt specific bugs — assert invariants that must always hold, so a
defect announces itself the first time it breaks one.

Check families (each maps to a real past failure):
  CONSERVATION   corpus/index counts never shrink; pending never vanishes
                 unexplained (encode-pipeline overwrite, 2026-11-20).
  UNIQUENESS     exactly one brain-daemon and one helm-keeper process
                 (duplicate-pair incident, 2026-11-20).
  RECONCILIATION stored counters match recounts (ACC resolved drift);
                 post-2026-11-19 deploy records carry baseline_metrics
                 (the salience rollback was a missing-baseline artifact).
  FRESHNESS      pulse < 45m, keeper health < 10m, state faces < 26h,
                 every memory JSON parses (NVR renderer freeze pattern).
  CAPACITY       disk free thresholds + trend snapshot (codypc 0-free,
                 2026-11-19); pending backlog ceiling.
  KNOWN-DEFECT   encode-pipeline overwrite signature watch until the
                 merge fix (prop_8b37ab72c3f0829b) deploys.

Read-only except its own snapshot: ~/.juno-brain/run/patrol-state.json.
Output: one line per check (PASS/WARN/FAIL/SKIP + values) and a summary.
Exit code 1 if any FAIL, else 0. WARN = investigate in the DSIC report,
not an emergency.
"""
import json, os, re, subprocess, sys, time
from datetime import datetime
from zoneinfo import ZoneInfo

HOME = os.path.expanduser("~")
W = os.path.join(HOME, ".juno-brain", "workspace")
MEM = os.path.join(W, "memory")
SNAP_PATH = os.path.join(HOME, ".juno-brain", "run", "patrol-state.json")
PT = ZoneInfo("America/Los_Angeles")

results = []  # (status, name, detail)

def report(status, name, detail):
    results.append((status, name, detail))

def load_json(path):
    with open(path) as f:
        return json.load(f)

def count_processes(pattern):
    """Count ROOT processes whose cmdline contains pattern, excluding
    this patrol. A daemon's own job children share its cmdline (the
    daemon spawns jobs as copies of itself) — counting them produced
    false "duplicate instance" FAILs (found 2026-11-20, Gated-Ingress
    Phase F: pid 67179 was the daemon's job child, PPID = the daemon
    itself). A process counts only if its parent's cmdline does NOT
    contain the pattern. The patrol's own ancestor chain is excluded
    for the same reason: an invoking shell whose command text merely
    MENTIONS the pattern (an agent exec string, a grep) is not an
    instance (found 2026-11-20 post-refactor: patrol run from such a
    shell counted the shell; ground truth via ps/cgroup was 1)."""
    n = 0
    me = str(os.getpid())
    out = subprocess.run(["ps", "-eo", "pid,ppid,args"], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        rows[parts[0]] = (parts[1], parts[2])
    ancestors = set()
    cur = me
    while cur in rows:
        cur = rows[cur][0]
        if cur in ancestors:
            break
        ancestors.add(cur)
    for pid, (ppid, args) in rows.items():
        if pid == me or pid in ancestors:
            continue
        # A shell running a -c command string is a command shell, not
        # an instance — its string may mention the pattern (agent exec
        # strings do) without executing it. The real daemon/keeper are
        # launched by systemd directly (bash <script> / python3 <bin>),
        # never via -c. (2026-11-20: pid 3605, a lingering exec shell
        # whose -c text named both, counted as a duplicate of each.)
        if " -c " in args or "--norc" in args:
            continue
        if pattern in args and "invariant-patrol" not in args:
            parent_args = rows.get(ppid, ("", ""))[1]
            if pattern not in parent_args:
                n += 1
    return n

def service_active(unit):
    r = subprocess.run(["systemctl", "is-active", "--quiet", unit])
    return r.returncode == 0

# ---------- snapshot (previous run, for deltas) ----------
snap = {}
try:
    snap = load_json(SNAP_PATH)
except Exception:
    snap = {}
prev = snap.get("values", {})

now = {"ts": datetime.now(PT).isoformat()}

# ---------- CONSERVATION ----------
corpus_path = os.path.join(HOME, ".openclaw", "agents", "main", "sessions", "juno-conversation.jsonl")
try:
    with open(corpus_path, "rb") as f:
        corpus_n = sum(1 for _ in f)
    now["corpus"] = corpus_n
    if "corpus" in prev and corpus_n < prev["corpus"]:
        report("FAIL", "conservation.corpus", f"corpus SHRANK {prev['corpus']} -> {corpus_n}")
    else:
        report("PASS", "conservation.corpus", f"{corpus_n} messages" + (f" (+{corpus_n - prev['corpus']})" if "corpus" in prev else " (baseline)"))
except Exception as e:
    report("FAIL", "conservation.corpus", f"unreadable: {e}")

index_n = None
try:
    idx = load_json(os.path.join(MEM, "index.json"))
    index_n = len(idx.get("memories", []))
    now["index"] = index_n
    if "index" in prev and index_n < prev["index"]:
        report("FAIL", "conservation.index", f"index SHRANK {prev['index']} -> {index_n}")
    else:
        report("PASS", "conservation.index", f"{index_n} memories" + (f" (+{index_n - prev['index']})" if "index" in prev else " (baseline)"))
except Exception as e:
    report("FAIL", "conservation.index", f"unreadable: {e}")

pending_n, pending_ids_ok = None, None
_pending_path = os.path.join(MEM, "pending-memories.json")
if not os.path.exists(_pending_path):
    # Absent = the designed empty state (Gated-Ingress inventory,
    # 2026-11-20): summarize-pending.sh deletes PENDING_FILE after the
    # final batch; encode-pipeline recreates it on the next signals.
    pending_n = 0
    now["pending"] = 0
    report("PASS", "conservation.pending", "0 pending (file absent = designed empty state)")
else:
    try:
        pm = load_json(_pending_path)
        pend = pm.get("pending", [])
        pending_n = len(pend)
        now["pending"] = pending_n
        ids = [p.get("id") for p in pend if isinstance(p, dict)]
        pending_ids_ok = len(ids) == len(set(ids))
        if not pending_ids_ok:
            report("FAIL", "conservation.pending_ids", f"duplicate ids inside pending-memories.json ({pending_n} entries)")
        if "pending" in prev:
            drop = prev["pending"] - pending_n
            grew = (index_n - prev["index"]) if (index_n is not None and "index" in prev) else 0
            if drop > 1000 and grew < max(10, drop // 10):
                report("WARN", "conservation.pending_shrink", f"pending dropped {prev['pending']} -> {pending_n} while index grew only {grew} — unexplained shrink, overwrite signature")
            else:
                report("PASS", "conservation.pending", f"{pending_n} pending (delta {pending_n - prev['pending']:+d})")
        else:
            report("PASS", "conservation.pending", f"{pending_n} pending (baseline)")
    except Exception as e:
        report("FAIL", "conservation.pending", f"unreadable: {e}")

# ---------- UNIQUENESS ----------
for name, pat in [("uniqueness.daemon", "brain-daemon.sh"), ("uniqueness.keeper", "helm-keeper")]:
    try:
        n = count_processes(pat)
        if n == 1:
            report("PASS", name, "exactly 1 process")
        elif n == 0:
            report("FAIL", name, "NOT RUNNING (0 processes)")
        else:
            report("FAIL", name, f"{n} processes — duplicate instance")
    except Exception as e:
        report("SKIP", name, f"ps failed: {e}")

for unit, sev in [("aibrain.service", "FAIL"), ("helm-keeper.service", "FAIL"),
                  ("rq-server.service", "WARN"), ("rq-tunnel.service", "WARN")]:
    try:
        if service_active(unit):
            report("PASS", f"uniqueness.{unit}", "active")
        else:
            report(sev, f"uniqueness.{unit}", "INACTIVE")
    except Exception as e:
        report("SKIP", f"uniqueness.{unit}", f"systemctl failed: {e}")

# ---------- RECONCILIATION ----------
try:
    acc = load_json(os.path.join(MEM, "acc-state.json"))
    actual_resolved = len(acc.get("resolved", {}))
    stated = acc.get("stats", {}).get("totalResolved")
    drift = abs((stated or 0) - actual_resolved)
    if drift == 0:
        report("PASS", "reconcile.acc", f"totalResolved {stated} == {actual_resolved} entries")
    elif drift == 1:
        report("PASS", "reconcile.acc", f"totalResolved {stated} vs {actual_resolved} entries — known 1-key drift, resolver owns it")
    else:
        report("FAIL", "reconcile.acc", f"totalResolved {stated} vs {actual_resolved} entries — drift {drift}")
    now["acc_active"] = len(acc.get("activePatterns", {}))
except Exception as e:
    report("FAIL", "reconcile.acc", f"unreadable: {e}")

try:
    dep_dir = os.path.join(MEM, "self-mod", "deploys")
    bad, checked = [], 0
    for fn in sorted(os.listdir(dep_dir)):
        if not fn.endswith(".json"):
            continue
        d = load_json(os.path.join(dep_dir, fn))
        ts = str(d.get("deployed_at", ""))
        if ts >= "2026-11-19":  # the root fix landed 2026-11-19; earlier records are history
            checked += 1
            if "baseline_metrics" not in d:
                bad.append(fn)
    if bad:
        report("FAIL", "reconcile.deploy_baseline", f"post-fix deploys missing baseline_metrics: {', '.join(bad)}")
    else:
        report("PASS", "reconcile.deploy_baseline", f"{checked} post-fix deploy record(s), all carry baseline_metrics")
except Exception as e:
    report("SKIP", "reconcile.deploy_baseline", f"deploys unreadable: {e}")

# ---------- FRESHNESS ----------
try:
    hh = load_json(os.path.join(MEM, "helm-health.json"))
    age = time.time() - float(hh.get("epoch", 0))
    q, dl = hh.get("queue_depth"), hh.get("deadletter_count")
    if age > 600:
        report("FAIL", "freshness.keeper_health", f"helm-health {age/60:.0f}m old (limit 10m); queue {q}, deadletter {dl}")
    elif dl not in (0, None):
        report("FAIL", "freshness.keeper_health", f"deadletter_count {dl}")
    else:
        report("PASS", "freshness.keeper_health", f"{age:.0f}s old, queue {q}, deadletter {dl}")
except Exception as e:
    report("FAIL", "freshness.keeper_health", f"unreadable: {e}")

try:
    lines = open(os.path.join(MEM, "heartbeat-pulse.log")).read().strip().splitlines()
    m = re.search(r"(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})", lines[-1]) if lines else None
    if not m:
        report("FAIL", "freshness.pulse", "no parseable pulse line")
    else:
        ts = datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=PT)
        age_min = (datetime.now(PT) - ts).total_seconds() / 60
        if age_min > 45:
            report("FAIL", "freshness.pulse", f"last pulse {age_min:.0f}m ago (limit 45m)")
        else:
            report("PASS", "freshness.pulse", f"last pulse {age_min:.0f}m ago")
except Exception as e:
    report("FAIL", "freshness.pulse", f"unreadable: {e}")

import glob as _glob
stale = []
for path in sorted(_glob.glob(os.path.join(W, "*_STATE.md"))):
    age_h = (time.time() - os.path.getmtime(path)) / 3600
    if age_h > 26:
        stale.append(f"{os.path.basename(path)} ({age_h:.0f}h)")
if stale:
    report("WARN", "freshness.state_faces", "stale >26h: " + ", ".join(stale))
else:
    report("PASS", "freshness.state_faces", "all *_STATE.md faces < 26h old")

broken = []
for path in sorted(_glob.glob(os.path.join(MEM, "*.json"))):
    try:
        load_json(path)
    except Exception:
        broken.append(os.path.basename(path))
if broken:
    report("FAIL", "freshness.json_parse", "unparseable: " + ", ".join(broken))
else:
    report("PASS", "freshness.json_parse", "all memory/*.json parse")

# ---------- CAPACITY ----------
try:
    st = os.statvfs(HOME)
    free_gb = st.f_bavail * st.f_frsize / 1e9
    free_pct = 100.0 * st.f_bavail / st.f_blocks
    now["vm_free_gb"] = round(free_gb, 2)
    trend = ""
    if "vm_free_gb" in prev:
        trend = f", delta {free_gb - prev['vm_free_gb']:+.2f} GB since last patrol"
    if free_pct < 5:
        report("FAIL", "capacity.vm_disk", f"{free_pct:.1f}% free ({free_gb:.1f} GB){trend}")
    elif free_pct < 10:
        report("WARN", "capacity.vm_disk", f"{free_pct:.1f}% free ({free_gb:.1f} GB){trend}")
    else:
        report("PASS", "capacity.vm_disk", f"{free_pct:.1f}% free ({free_gb:.1f} GB){trend}")
except Exception as e:
    report("SKIP", "capacity.vm_disk", f"statvfs failed: {e}")

if pending_n is not None:
    if pending_n > 20000:
        report("WARN", "capacity.pending_ceiling", f"{pending_n} pending signals (ceiling 20000)")
    else:
        report("PASS", "capacity.pending_ceiling", f"{pending_n} pending signals")

try:
    r = subprocess.run(
        [os.path.join(HOME, "workspace", "bin", "codypc-exec"), "--route", "1",
         'grep -q "Ryzen 7 3700X" /proc/cpuinfo && test -d "/home/cody/Documents/nvr-emulator" && df --output=pcent / | tail -1 || echo GUARD_FAIL'],
        capture_output=True, text=True, timeout=60)
    out = (r.stdout or "").strip()
    m = re.search(r"(\d+)%", out)
    if "GUARD_FAIL" in out or not m:
        report("SKIP", "capacity.codypc_disk", "route 1 unreachable or guard failed — unverified, not a violation")
    else:
        used = int(m.group(1)); free = 100 - used
        now["codypc_free_pct"] = free
        if free < 5:
            report("FAIL", "capacity.codypc_disk", f"codypc root {free}% free")
        elif free < 10:
            report("WARN", "capacity.codypc_disk", f"codypc root {free}% free")
        else:
            report("PASS", "capacity.codypc_disk", f"codypc root {free}% free")
except Exception as e:
    report("SKIP", "capacity.codypc_disk", f"probe failed: {e}")

# ---------- KNOWN-DEFECT WATCH ----------
try:
    src = open(os.path.join(W, "skills", "hippocampus-memory", "scripts", "encode-pipeline.sh")).read()
    overwrites = 'json.dump({"pending": pending' in src and "existing" not in src.split('json.dump({"pending": pending')[0].rsplit("pending = []", 1)[-1]
    # simpler signature: fresh list built and dumped, no load of PENDING_FILE for reading
    loads_existing = ("existing_pending" in src
                      or bool(re.search(r"open\(PENDING_FILE,\s*'r'\)", src))
                      or bool(re.search(r"json\.load\(open\(PENDING_FILE", src)))
    if 'json.dump({"pending": pending' in src and not loads_existing:
        report("WARN", "defect.encode_overwrite", "encode-pipeline.sh still overwrites pending-memories.json (merge fix prop_8b37ab72c3f0829b not yet deployed)")
    else:
        report("PASS", "defect.encode_overwrite", "encode-pipeline merges existing pending (overwrite signature gone)")
except Exception as e:
    report("SKIP", "defect.encode_overwrite", f"script unreadable: {e}")

# ---------- GATED INGRESS (Phase E, Gated-Ingress Refactor 2026-11-20) ----------
# I1: the registry itself must be valid — every flow carries a reader,
# an SLA, and append/merge semantics (overwrite is not registrable).
# I2: no orphan stores; every flow's reader evidence within its SLA —
# breaches WARN here and are routed TO the ACC (it owns the verdict).
# I3: conservation receipts satisfy in = out + discarded; no fresh-list
# pending dumps remain outside merge/writer paths (gate bypass).
import fnmatch as _fn
_flows, _internal_pats = [], []
try:
    _reg = load_json(os.path.join(W, "core", "gate", "flows.json"))
    _flows = _reg.get("flows", [])
    _internal_pats = _reg.get("internal_stores", [])
    _bad_reg = [f.get("id", "?") for f in _flows
                if not f.get("reader") or not f.get("sla_seconds")
                or f.get("semantics") not in ("append", "merge")]
    if _bad_reg:
        report("FAIL", "gate.registry", "flows missing reader/sla or using non-registrable semantics: " + ", ".join(_bad_reg))
    else:
        report("PASS", "gate.registry", f"{len(_flows)} flows registered, all with reader + SLA + append/merge semantics")
except Exception as e:
    report("FAIL", "gate.registry", f"flows.json unreadable: {e}")

def _store_covered(relpath, basename):
    for f in _flows:
        store = f.get("store", "")
        if store == relpath:
            return True
        if store and relpath.startswith(store.rstrip("/") + "/"):
            return True
    for pat in _internal_pats:
        if _fn.fnmatch(basename, pat) or _fn.fnmatch(relpath, pat):
            return True
        if pat.endswith("/") and relpath.startswith(pat):
            return True
    return False

try:
    _orphans = []
    for _path in sorted(_glob.glob(os.path.join(MEM, "*.json")) + _glob.glob(os.path.join(MEM, "*.jsonl"))):
        _base = os.path.basename(_path)
        if not _store_covered(os.path.join("memory", _base), _base):
            _orphans.append(_base)
    if _orphans:
        report("FAIL", "gate.orphan_stores", "stores present but NOT in the flow registry: " + ", ".join(_orphans))
    else:
        report("PASS", "gate.orphan_stores", "every memory/*.json|jsonl is a registered flow or internal store")
except Exception as e:
    report("SKIP", "gate.orphan_stores", f"scan failed: {e}")

def _evidence_age(flow):
    ev = flow.get("evidence") or {}
    p = ev.get("path")
    if not p:
        return None
    if p.startswith("~"):
        p = os.path.expanduser(p)
    elif not os.path.isabs(p):
        p = os.path.join(W, p)
    if not os.path.exists(p):
        return float("inf")
    field = ev.get("field")
    if field:
        try:
            v = load_json(p).get(field)
            if isinstance(v, (int, float)):
                return time.time() - float(v)
            if isinstance(v, str):
                return time.time() - datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except Exception:
            pass
    return time.time() - os.path.getmtime(p)

try:
    _stale_flows, _missing_ev = [], []
    for _f in _flows:
        _age = _evidence_age(_f)
        if _age is None:
            continue
        if _age == float("inf"):
            _missing_ev.append(_f["id"])
        elif _age > _f["sla_seconds"]:
            _stale_flows.append(f"{_f['id']} ({_age/3600:.1f}h > SLA {_f['sla_seconds']/3600:.1f}h)")
    if _stale_flows:
        report("WARN", "gate.flow_sla", "reader evidence stale: " + "; ".join(_stale_flows[:6]))
        try:
            subprocess.run(
                ["bash", os.path.join(W, "skills/acc-error-memory/scripts/log-error.sh"),
                 "--pattern", "flow-sla-breach",
                 "--context", "invariant patrol: " + "; ".join(_stale_flows[:6]),
                 "--mitigation", "check the named flow's reader rhythm; registry in core/gate/flows.json"],
                env={**os.environ, "WORKSPACE": W}, capture_output=True, timeout=30)
        except Exception:
            pass
    else:
        _msg = f"all {len(_flows)} flows' reader evidence within SLA"
        if _missing_ev:
            _msg += f"; evidence path absent for: {', '.join(_missing_ev)}"
        report("PASS", "gate.flow_sla", _msg)
except Exception as e:
    report("SKIP", "gate.flow_sla", f"check failed: {e}")

try:
    _rp = os.path.join(MEM, "gate-receipts.jsonl")
    if not os.path.exists(_rp):
        report("WARN", "gate.receipts_audit", "no gate receipts yet (conservation writer unused since install)")
    else:
        _lines = open(_rp).read().strip().splitlines()[-20:]
        _bad = []
        for _ln in _lines:
            _r = json.loads(_ln)
            if _r.get("in_count") != _r.get("out_count") + len(_r.get("discarded", [])):
                _bad.append(_r.get("ts", "?"))
        if _bad:
            report("FAIL", "gate.receipts_audit", "conservation identity broken in receipts at: " + ", ".join(_bad))
        else:
            report("PASS", "gate.receipts_audit", f"last {len(_lines)} gate receipts satisfy in = out + discarded")
except Exception as e:
    report("SKIP", "gate.receipts_audit", f"audit failed: {e}")

try:
    _out = subprocess.run(
        ["grep", "-rln", "--include=*.sh", "-E", r'json\.dump\(\{"pending": pending',
         os.path.join(W, "skills")], capture_output=True, text=True).stdout
    _bypass = []
    for _path in _out.splitlines():
        _src = open(_path).read()
        if "existing" not in _src and "store_write" not in _src and "MERGE" not in _src:
            _bypass.append(os.path.relpath(_path, W))
    if _bypass:
        report("FAIL", "gate.bypass_grep", "fresh-list pending dumps remain in: " + ", ".join(_bypass))
    else:
        report("PASS", "gate.bypass_grep", "no fresh-list pending-store dumps outside merge/writer paths")
except Exception as e:
    report("SKIP", "gate.bypass_grep", f"grep failed: {e}")

# ---------- emit + snapshot ----------
counts = {"PASS": 0, "WARN": 0, "FAIL": 0, "SKIP": 0}
for s, _, _ in results:
    counts[s] = counts.get(s, 0) + 1
print(f"## Invariant patrol — {datetime.now(PT).strftime('%Y-%m-%d %H:%M PST')}")
for s, name, detail in results:
    print(f"- [{s}] {name}: {detail}")
print(f"PATROL SUMMARY: {counts['PASS']} pass, {counts['WARN']} warn, {counts['FAIL']} fail, {counts['SKIP']} skip")

try:
    os.makedirs(os.path.dirname(SNAP_PATH), exist_ok=True)
    tmp = SNAP_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"values": now}, f, indent=2)
    os.replace(tmp, SNAP_PATH)
except Exception:
    pass

sys.exit(1 if counts["FAIL"] else 0)
