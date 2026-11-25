#!/usr/bin/env python3
# filter-pending.py — the immune system's self / non-self recognition for the
# memory pipeline. Classifies every pending signal before summarization:
#
#   clean      — provenance is Juno/Dither conversation; may flow to
#                summarize-pending automatically.
#   review     — mixed signals; a Juno turn decides by hand.
#   quarantine — instruction packets and worker boilerplate from other
#                agents' sessions. NEVER summarized into memory and never
#                treated as instructions. Kept on disk for audit.
#
# Deterministic rules only; every non-clean item carries its reasons.
# The original pending file is never modified.
# Juno Moneta, 2026-11-24.
import json, os, re, sys

WS = os.environ.get("WORKSPACE", os.path.expanduser("~/.juno-brain/workspace"))
MEM = os.path.join(WS, "memory")
PENDING = os.path.join(MEM, "pending-memories.json")
CLEAN_OUT = os.path.join(MEM, "pending-clean.json")
HELD_OUT = os.path.join(MEM, "pending-held.json")

PACKET_MARKERS = [
    (r"step instructions", "step-instructions packet"),
    (r"carry out this assignment", "assignment packet"),
    (r"previous step results", "pipeline step packet"),
    (r"available lanes", "worker lane packet"),
    (r"return zero or more", "worker output contract"),
    (r"emit at most one", "worker output contract"),
    (r"system message|developer message", "embedded system/developer text"),
    (r"verbatim_request", "artifact build packet"),
    (r"the media stage|the sources audit|the taste stage", "feed production stage"),
    (r"reading daypart", "feed production stage"),
    (r"open this .* link and read", "link-fetch assignment"),
    (r"report back:", "assignment packet"),
    (r"## step\b", "pipeline step packet"),
    (r"your units are drafted", "feed production stage"),
    (r"evaluate one tracking goal|evaluate the supplied candidates", "tracking worker packet"),
    (r"order the people and groups in this user", "relationships worker packet"),
]
FIRST_PERSON = re.compile(r"\b(I|I'm|I've|my|me|Dither|you)\b")

def classify(item):
    text = item.get("raw_text", "") or ""
    low = text.lower()
    reasons = []
    for pat, name in PACKET_MARKERS:
        if re.search(pat, low):
            reasons.append(name)
    headings = text.count("\n## ") + (1 if text.startswith("## ") else 0)
    if headings >= 2:
        reasons.append("multi-heading scaffold (%d)" % headings)
    imperatives = len(re.findall(r"\b(return|emit|use|find|open|read|write|run|check|deliver|create)\b", low))
    if len(text) > 1200 and imperatives >= 12:
        reasons.append("long imperative-dense text (%d imperatives)" % imperatives)
    if reasons:
        return "quarantine", reasons
    if len(text) > 1200:
        return "review", ["long text, no packet markers — human pass"]
    if item.get("role") == "user":
        return "clean", ["user role, no packet markers"]
    if FIRST_PERSON.search(text):
        return "clean", ["conversational first/second person, no packet markers"]
    return "review", ["no packet markers, no conversational markers"]

def main():
    d = json.load(open(PENDING))
    items = d.get("pending", [])
    clean, review, quarantine = [], [], []
    for it in items:
        bucket, reasons = classify(it)
        rec = dict(it)
        rec["filterReasons"] = reasons
        {"clean": clean, "review": review, "quarantine": quarantine}[bucket].append(rec)
    json.dump({"created": d.get("created"), "clean": clean}, open(CLEAN_OUT, "w"), indent=1)
    json.dump({"review": review, "quarantine": quarantine}, open(HELD_OUT, "w"), indent=1)
    print("pending=%d clean=%d review=%d quarantine=%d" % (len(items), len(clean), len(review), len(quarantine)))
    return 0

if __name__ == "__main__":
    sys.exit(main())
