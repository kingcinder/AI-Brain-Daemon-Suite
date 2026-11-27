#!/usr/bin/env python3
"""process-stream.py — the insula's nerve (built 2026-11-27, Dither-ordered).

Juno's process stream — her work record and her deliberation — is PROCESSED
by the harness and NEVER KEPT. This processor reads JSONL process events in
memory and emits only derived features: marker counts, a loop score, affect
proxies, claim tallies, and SHA-256 digests. Raw event text is hashed, never
written: not to the state file, not to the features log, not to the claims
file (claims persist as hashes only). A raw string from the stream appearing
in any output file is a defect on the order of an immune jam.

Modes:
  feed   Collect new work-record events since the byte-offset watermark
         (keeper results, doctor ledger, daemon log, transcript claims)
         and process them as one batch.
  tap    Read JSONL events from stdin (Juno's live tap) and process them.

Derived outputs (features and digests only):
  memory/process-stream-state.json     totals, rolling features, proxies
  memory/process-stream-features.jsonl one derived line per batch
  memory/process-stream-claims.jsonl   unbacked-claim candidates, hash only

When a batch carries deliberation or claim signal, the insula's channels
(friction, cognitiveLoad, selfCoherence) are nudged by bounded deltas via
the organ's own update-state.sh. Pure work batches never move the channels:
the harness's noise is not Juno's state.
"""
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

WORKSPACE = Path(os.environ.get("WORKSPACE") or os.environ.get("OPENCLAW_WORKSPACE")
                 or Path.home() / ".juno-brain" / "workspace")
MEM = WORKSPACE / "memory"
STATE_PATH = MEM / "process-stream-state.json"
FEATURES_PATH = MEM / "process-stream-features.jsonl"
CLAIMS_PATH = MEM / "process-stream-claims.jsonl"
WATERMARK_PATH = MEM / "process-stream-watermark.json"
UPDATE_STATE = WORKSPACE / "skills" / "insula-memory" / "scripts" / "update-state.sh"

FRICTION = ["no.", "no,", "not ", "wrong", "refuse", "refused", "never", "fail",
            "broken", "error", "jam", "stuck", "blocked", "cannot", "can't",
            "won't", "hold on", "wait,"]
CERTAINTY = ["verified", "confirmed", "proven", "exactly", "definitely",
             "clearly", "i checked", "live"]
REPAIR = ["fixed", "repair", "repaired", "restore", "restored", "corrected",
          "recheck", "re-check", "verify", "verified", "resolved"]
HESITATION = ["maybe", "perhaps", "not sure", "uncertain", "i don't know",
              "unknown", "guess", "probably"]
CLAIM_RE = re.compile(
    r"\b(?:i|we)\s+(?:have\s+)?(installed|restarted|verified|fixed|repaired|"
    r"built|pushed|committed|created|wrote|updated|delivered|sent|completed|"
    r"finished|removed|deleted|configured|launched|started|stopped)\b", re.I)
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9\-]{4,}")


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def count_markers(text, markers):
    low = " " + text.lower() + " "
    return sum(low.count(m) for m in markers)


def loop_score(text):
    """Repeated 4-gram ratio: 0 = no repetition, ->1 = heavy looping."""
    words = re.findall(r"[a-z']+", text.lower())
    if len(words) < 12:
        return 0.0
    grams = [" ".join(words[i:i + 4]) for i in range(len(words) - 3)]
    if not grams:
        return 0.0
    repeated = len(grams) - len(set(grams))
    return round(repeated / len(grams), 4)


def text_features(text):
    words = max(1, len(re.findall(r"\S+", text)))
    return {
        "words": words,
        "friction": count_markers(text, FRICTION),
        "certainty": count_markers(text, CERTAINTY),
        "repair": count_markers(text, REPAIR),
        "hesitation": count_markers(text, HESITATION),
        "loop": loop_score(text),
    }


def significant_tokens(text):
    return set(TOKEN_RE.findall(text.lower()))


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def save_json(path, obj):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1))
    tmp.replace(path)


def nudge_insula(feat, counts):
    """Bounded channel deltas from derived features, via the organ's own
    writer. Only called when the batch carries deliberation/claim signal."""
    intero = load_json(MEM / "interoceptive-state.json", {})
    ch = intero.get("channels", {})
    if not ch:
        return
    words = max(1, feat["words"])
    friction_rate = min(1.0, feat["friction"] / (words / 40.0))
    load_rate = min(1.0, (feat["friction"] + feat["certainty"] + feat["repair"]
                          + feat["hesitation"]) / (words / 30.0))
    d_friction = max(-0.06, min(0.06, (friction_rate - 0.25) * 0.12))
    d_load = max(-0.06, min(0.06, (load_rate - 0.3) * 0.12))
    d_coh = 0.0
    if feat["loop"] >= 0.25:
        d_coh -= 0.04
    if counts.get("unbackedClaims", 0) > 0:
        d_coh -= 0.03
    if feat["repair"] > 0 and counts.get("unbackedClaims", 0) == 0:
        d_coh += 0.02
    env = dict(os.environ, OPENCLAW_WORKSPACE=str(WORKSPACE))
    for channel, delta in (("friction", d_friction), ("cognitiveLoad", d_load),
                           ("selfCoherence", d_coh)):
        if abs(delta) < 0.005:
            continue
        new_val = round(max(0.0, min(1.0, ch.get(channel, 0.0) + delta)), 3)
        try:
            subprocess.run(["bash", str(UPDATE_STATE), "--channel", channel,
                            "--set", str(new_val)],
                           env=env, capture_output=True, timeout=30)
        except Exception as e:
            print("insula nudge failed: %s" % e, file=sys.stderr)


def process_batch(events, source):
    """Events are dicts {ts, kind, text?, meta?}. Raw text is used in memory
    only; everything persisted is counts, features, or hashes."""
    counts = {"work": 0, "deliberation": 0, "claim": 0, "other": 0}
    agg = {"words": 0, "friction": 0, "certainty": 0, "repair": 0,
           "hesitation": 0, "loop": 0.0}
    digest = hashlib.sha256()
    work_tokens = set()
    claims = []
    for ev in events:
        kind = ev.get("kind", "other")
        counts[kind if kind in counts else "other"] += 1
        text = ev.get("text") or ""
        if text:
            digest.update(text.encode("utf-8", "replace"))
            digest.update(b"\n")
            f = text_features(text)
            for k in ("words", "friction", "certainty", "repair", "hesitation"):
                agg[k] += f[k]
            agg["loop"] = max(agg["loop"], f["loop"])
            if kind == "work":
                work_tokens |= significant_tokens(text)
        if kind == "claim":
            claims.append(ev)
    # Claim backing: explicit evidence flag, or a significant token shared
    # with the batch's work record. Candidates only — never verdicts.
    backed = 0
    unbacked_lines = []
    for ev in claims:
        text = ev.get("text") or ""
        meta = ev.get("meta") or {}
        is_backed = meta.get("evidence") is True or bool(
            significant_tokens(text) & work_tokens)
        if is_backed:
            backed += 1
        else:
            unbacked_lines.append({
                "ts": ev.get("ts") or now_iso(),
                "claimHash": hashlib.sha256(
                    " ".join(text.lower().split()).encode()).hexdigest(),
                "verb": (meta.get("verb") or "unknown"),
                "backed": False,
                "source": source,
            })
    counts["claims"] = len(claims)
    counts["backedClaims"] = backed
    counts["unbackedClaims"] = len(unbacked_lines)
    words = max(1, agg["words"])
    valence = math.tanh((agg["certainty"] + agg["repair"] - agg["friction"]
                         - agg["hesitation"]) / max(1.0, words / 60.0))
    arousal = min(1.0, (agg["friction"] + agg["certainty"] + agg["repair"]
                        + agg["hesitation"]) / max(1.0, words / 25.0))
    features = {
        "ts": now_iso(), "source": source, "counts": counts,
        "words": agg["words"], "friction": agg["friction"],
        "certainty": agg["certainty"], "repair": agg["repair"],
        "hesitation": agg["hesitation"], "loop": agg["loop"],
        "affectProxies": {"valence": round(valence, 3),
                          "arousal": round(arousal, 3)},
        "batchDigest": digest.hexdigest(),
    }
    MEM.mkdir(parents=True, exist_ok=True)
    with open(FEATURES_PATH, "a") as fh:
        fh.write(json.dumps(features) + "\n")
    if unbacked_lines:
        with open(CLAIMS_PATH, "a") as fh:
            for line in unbacked_lines:
                fh.write(json.dumps(line) + "\n")
    state = load_json(STATE_PATH, {"totals": {}, "batches": 0, "rolling": []})
    totals = state.get("totals", {})
    for k, v in counts.items():
        totals[k] = totals.get(k, 0) + v
    state["totals"] = totals
    state["batches"] = state.get("batches", 0) + 1
    state["lastBatch"] = features
    state["rolling"] = (state.get("rolling", []) + [features])[-20:]
    state["lastProcessedAt"] = features["ts"]
    save_json(STATE_PATH, state)
    if counts.get("deliberation", 0) > 0 or counts.get("claims", 0) > 0:
        nudge_insula(agg, counts)
    return features


# ---------------------------------------------------------------- feeder ---

TAIL_BYTES = 512_000  # first sight of a source: start at most this far back


def read_new(path, offsets):
    """Return (new_text, new_offset) for a file, byte-offset watermarked."""
    try:
        size = path.stat().st_size
    except Exception:
        return "", offsets.get(str(path), 0)
    start = offsets.get(str(path))
    if start is None or start > size:
        start = max(0, size - TAIL_BYTES)
    with open(path, "rb") as fh:
        fh.seek(start)
        data = fh.read()
    if start > 0:
        nl = data.find(b"\n")
        if nl >= 0:
            data = data[nl + 1:]
    return data.decode("utf-8", "replace"), size


def feed():
    offsets = load_json(WATERMARK_PATH, {})
    events = []

    def collect(path, fn):
        text, new_off = read_new(path, offsets)
        if text:
            for line in text.splitlines():
                line = line.strip()
                if line:
                    fn(line, events)
            offsets[str(path)] = new_off

    def from_results(line, out):
        try:
            d = json.loads(line)
        except Exception:
            return
        resp = d.get("response")
        if isinstance(resp, str) and resp.strip():
            out.append({"kind": "work", "text": resp})

    def from_ledger(line, out):
        try:
            d = json.loads(line)
        except Exception:
            out.append({"kind": "work", "text": line[:200]})
            return
        text = " ".join(str(d.get(k, "")) for k in
                        ("action", "aspect", "result", "detail", "status"))
        out.append({"kind": "work", "text": text or line[:200]})

    def from_daemon_log(line, out):
        out.append({"kind": "work", "text": line[:500]})

    def from_transcript(line, out):
        try:
            d = json.loads(line)
        except Exception:
            return
        msg = d.get("message") or {}
        if msg.get("role") != "assistant":
            return
        content = msg.get("content")
        if not isinstance(content, str):
            return
        for sent in re.split(r"(?<=[.!?])\s+", content):
            m = CLAIM_RE.search(sent)
            if m:
                out.append({"kind": "claim", "text": sent[:400],
                            "ts": d.get("timestamp"),
                            "meta": {"verb": m.group(1).lower()}})

    collect(MEM / "spawn-results.jsonl", from_results)
    collect(Path.home() / "workspace" / "memory-backups" / "doctor-ledger.jsonl",
            from_ledger)
    collect(MEM / "daemon-job-output.log", from_daemon_log)
    collect(WORKSPACE / "transcripts" / "corpus" / "juno-conversation.jsonl",
            from_transcript)
    save_json(WATERMARK_PATH, offsets)
    if not events:
        print(json.dumps({"source": "feed", "events": 0}))
        return
    print(json.dumps(process_batch(events, "feed")))


def tap():
    events = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if isinstance(ev, dict) and ev.get("kind"):
            events.append(ev)
    if not events:
        print(json.dumps({"source": "tap", "events": 0}))
        return
    print(json.dumps(process_batch(events, "tap")))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "feed"
    if mode == "feed":
        feed()
    elif mode == "tap":
        tap()
    else:
        print("usage: process-stream.py [feed|tap]", file=sys.stderr)
        sys.exit(2)
