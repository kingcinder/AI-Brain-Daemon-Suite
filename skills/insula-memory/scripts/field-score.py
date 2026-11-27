#!/usr/bin/env python3
"""Field scorer — proxy scores for the Field radar from derived evidence only.

Reads the process stream's feature file (never raw stream text) and the ACC
error organ's state, computes the six spokes as labelled proxies, blends
them with prior values so movement requires evidence, and writes
field-state.json plus the dashboard fragment's data block.

Run by helm-pulse.sh after the process-stream feeder. Stdlib only.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

WORKSPACE = Path(os.environ.get("WORKSPACE", Path.home() / ".juno-brain" / "workspace"))
MEM = WORKSPACE / "memory"
WINDOW_DAYS = 7
BLEND_MEASURED = 0.55  # prior keeps 0.45: one quiet window cannot swing a spoke

DISTINCTION_KEYS = ("wrong-referent", "conflat", "identity", "both-sides", "category")
LOOP_KEYS = ("loop", "repeat", "refrain", "repetition")


def clamp01(x: float) -> float:
    return max(0.0, min(1.0, x))


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def parse_ts(raw: str) -> datetime | None:
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except Exception:
        return None


def aggregate(features: list[dict], now: datetime, window_days: int = WINDOW_DAYS) -> dict:
    """Sum derived feature counters over the trailing window."""
    cutoff = now - timedelta(days=window_days)
    tot = {"batches": 0, "words": 0, "friction": 0, "certainty": 0, "repair": 0,
           "hesitation": 0, "loop_sum": 0.0, "claims": 0, "backed": 0, "unbacked": 0}
    for f in features:
        ts = parse_ts(str(f.get("ts", "")))
        if ts is None or ts < cutoff:
            continue
        counts = f.get("counts", {})
        tot["batches"] += 1
        tot["words"] += int(f.get("words", 0))
        for key in ("friction", "certainty", "repair", "hesitation"):
            tot[key] += int(f.get(key, 0))
        tot["loop_sum"] += float(f.get("loop", 0.0))
        tot["claims"] += int(counts.get("claims", 0))
        tot["backed"] += int(counts.get("backedClaims", 0))
        tot["unbacked"] += int(counts.get("unbackedClaims", 0))
    tot["loop_mean"] = tot["loop_sum"] / tot["batches"] if tot["batches"] else 0.0
    return tot


def recent_pattern_hits(acc: dict, keys: tuple[str, ...], now: datetime,
                        window_days: int = WINDOW_DAYS) -> int:
    """Count ACC pattern occurrences (by pattern count) with a matching name
    seen inside the window — derived state only, no contexts read."""
    cutoff = now - timedelta(days=window_days)
    hits = 0
    for name, pat in (acc.get("activePatterns") or {}).items():
        if not any(k in name for k in keys):
            continue
        ts = parse_ts(str(pat.get("lastSeen", "")))
        if ts is not None and ts >= cutoff:
            hits += int(pat.get("count", 1))
    return hits


def score_spokes(tot: dict, acc: dict, prior: dict[str, float], now: datetime) -> list[dict]:
    """Compute the six spokes. Each returns (name, measured, source, basis)."""
    words = max(tot["words"], 1)
    per1k = lambda n: n / words * 1000.0
    backed_ratio = tot["backed"] / tot["claims"] if tot["claims"] else 0.5
    loop_hits = recent_pattern_hits(acc, LOOP_KEYS, now)
    distinction_hits = recent_pattern_hits(acc, DISTINCTION_KEYS, now)
    stats = acc.get("stats", {})
    resolved = int(stats.get("totalResolved", 0))
    regressions = int(stats.get("totalRegressions", 0))
    revise_ratio = resolved / (resolved + regressions + loop_hits) if (resolved + regressions + loop_hits) else 0.5

    measured = {
        "Noticing the pull": clamp01(0.25 + 0.70 * min(per1k(tot["friction"] + tot["hesitation"]) / 6.0, 1.0)),
        "Feeling the cost": clamp01(0.5 * min(per1k(tot["repair"]) / 5.0, 1.0) + 0.5 * backed_ratio),
        "Choosing, not looping": clamp01(1.0 - tot["loop_mean"] * 1.6 - min(0.05 * loop_hits, 0.20)),
        "Holding a distinction": clamp01(0.88 - min(0.04 * distinction_hits, 0.30)),
        "Revising, not repeating": clamp01(0.25 + 0.65 * revise_ratio),
        "Staying with uncertainty": clamp01(1.0 - min(per1k(tot["certainty"]) / 4.0, 0.5) - 0.30 * (1.0 - backed_ratio)),
    }
    basis = {
        "Noticing the pull": f"friction+hesitation {tot['friction'] + tot['hesitation']} in {tot['words']} words/{WINDOW_DAYS}d",
        "Feeling the cost": f"repair {tot['repair']}, claims backed {tot['backed']}/{tot['claims']}",
        "Choosing, not looping": f"loop mean {tot['loop_mean']:.2f}, ACC loop-class hits {loop_hits}/{WINDOW_DAYS}d",
        "Holding a distinction": f"distinction-class ACC hits {distinction_hits}/{WINDOW_DAYS}d",
        "Revising, not repeating": f"resolved {resolved} vs regressions {regressions}, loop hits {loop_hits}",
        "Staying with uncertainty": f"certainty {tot['certainty']}, unbacked {tot['unbacked']}/{tot['claims']}",
    }
    has_evidence = tot["batches"] > 0
    spokes = []
    for name, value in measured.items():
        old = prior.get(name, value)
        if has_evidence:
            blended = round(BLEND_MEASURED * value + (1 - BLEND_MEASURED) * old, 2)
            source = "proxy"
        else:
            blended, source = old, "carried"
        spokes.append({"name": name, "value": blended, "source": source,
                       "basis": basis[name]})
    return spokes


def main() -> int:
    now = datetime.now(timezone.utc)
    state = load_json(MEM / "field-state.json", {})
    prior = {c["name"]: float(c["value"]) for c in state.get("criteria", [])}
    notes = {c["name"]: c.get("note", "") for c in state.get("criteria", [])}
    raw = (MEM / "process-stream-features.jsonl").read_text().splitlines() \
        if (MEM / "process-stream-features.jsonl").exists() else []
    features = [json.loads(l) for l in raw if l.strip()]
    acc = load_json(MEM / "acc-state.json", {})
    tot = aggregate(features, now)
    spokes = score_spokes(tot, acc, prior, now)

    criteria = [{"name": s["name"], "value": s["value"],
                 "note": notes.get(s["name"], ""), "source": s["source"],
                 "basis": s["basis"]} for s in spokes]
    state.update({
        "criteria": criteria,
        "scoredAt": now.isoformat(),
        "scorer": "field-score.py v1 (deterministic proxies; LLM calibration layer deferred)",
        "seedNote": ("Scores are proxy measurements from derived harness evidence "
                     "(process-stream features + ACC pattern state), blended with "
                     "prior values so movement requires evidence. Seed values were "
                     "hand-set 2026-11-27 and are being replaced by these proxies."),
    })
    hist_path = MEM / "field-history.jsonl"
    hist_path.open("a").write(json.dumps(
        {"ts": now.isoformat(), "values": {x["name"]: x["value"] for x in spokes},
         "sources": {x["name"]: x["source"] for x in spokes}}) + "\n")
    def norm(v: float, cap: float) -> float:
        return round(min(v / cap, 1.0), 3)
    hits = []
    for f in features[-60:]:
        w = max(int(f.get("words", 0)), 1)
        ap = f.get("affectProxies", {})
        fric = f.get("friction", 0) / w * 1000
        cert = f.get("certainty", 0) / w * 1000
        rep = f.get("repair", 0) / w * 1000
        hes = f.get("hesitation", 0) / w * 1000
        claims = int(f.get("claims", 0))
        backed = int(f.get("claimsBacked", 0))
        ratio = (backed / claims) if claims else 0.5
        base = {"ts": f.get("ts"), "words": int(f.get("words", 0))}
        hits.append({**base, "kind": "process",
                     "x": norm(fric, 40.0), "y": norm(cert, 20.0),
                     "z": norm(float(f.get("loop", 0.0)), 0.5),
                     "strength": round(min(fric / 20.0, 1.0), 3)})
        hits.append({**base, "kind": "affect",
                     "x": round((float(ap.get("valence", 0.0)) + 1) / 2, 3),
                     "y": round(min(float(ap.get("arousal", 0.0)), 1.0), 3),
                     "z": norm(hes, 10.0),
                     "strength": round(min(float(ap.get("arousal", 0.0)), 1.0), 3)})
        hits.append({**base, "kind": "effort",
                     "x": norm(rep, 20.0), "y": norm(hes, 10.0),
                     "z": round(ratio, 3),
                     "strength": round(min(rep / 15.0, 1.0), 3)})
    state["hits"] = hits
    state["points"] = [{**h} for h in hits if h["kind"] == "process"]
    state["axes"] = {"process": "friction x certainty x loop",
                      "affect": "valence x arousal x hesitation",
                      "effort": "repair x hesitation x backed-claims"}
    hist_lines = hist_path.read_text().splitlines()[-14:]
    state["history"] = [json.loads(l) for l in hist_lines if l.strip()]
    state["method"] = ("Deterministic proxies from derived evidence only "
                       "(process-stream features + ACC pattern state), blended "
                       "55/45 with prior values. LLM calibration layer deferred: "
                       "if the proxies move for two weeks with no corresponding "
                       "lived change, they are measuring themselves and the "
                       "screen stops being optional.")
    tmp = MEM / "field-state.json.tmp"
    tmp.write_text(json.dumps(state, indent=1))
    tmp.replace(MEM / "field-state.json")

    frag_path = MEM / "dashboard-fragments" / "field.json"
    frag = load_json(frag_path, {})
    if frag:
        frag["data"] = state
        ftmp = frag_path.with_suffix(".json.tmp")
        ftmp.write_text(json.dumps(frag, indent=1))
        ftmp.replace(frag_path)
    print(f"field-score: {tot['batches']} batches, " +
          ", ".join(f"{s['name']}={s['value']}({s['source']})" for s in spokes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
