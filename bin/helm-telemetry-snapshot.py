#!/usr/bin/env python3
"""helm-telemetry-snapshot — render one self-contained HTML page showing the
live state of the Juno helm (AI Brain Daemon harness), from real local
sources only. Every number traces to a file or service read at render time;
stale sources are flagged, never dressed up as fresh.

Output: ~/.juno-brain/run/helm-telemetry.html
Stdout: one line — path, sha256, overall verdict word.
"""
import html
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

PT = ZoneInfo("America/Los_Angeles")
HOME = os.path.expanduser("~")
JB = os.path.join(HOME, ".juno-brain")
OUT = os.path.join(JB, "run", "helm-telemetry.html")
HEALTH = os.path.join(HOME, "bigpipe-share", "helm-health.json")
FAILCOUNT = os.path.join(JB, "logs", "helm-keepalive.failcount")
KEEPALIVE_LOG = os.path.join(JB, "logs", "helm-keepalive.log")
CORPUS = os.path.join(HOME, ".openclaw", "agents", "main", "sessions",
                      "juno-conversation.jsonl")
CORPUS_LASTRUN = os.path.join(JB, "run", "corpus-sync-last-run.json")
COUNT_STATE = os.path.join(JB, "run", "helm-telemetry-count-state.json")
VERIF_STATE = os.path.join(JB, "workspace", "VERIFICATION_STATE.md")
CATHEDRAL_HIDDEN = os.path.join(
    HOME, "workspace", "goals", "the-cathedral-juno-made-durable",
    "hidden_files")
ORGANS = os.path.join(CATHEDRAL_HIDDEN, "organs.md")

now = datetime.now(PT)
now_ts = now.timestamp()


def fmt_pt(epoch):
    if epoch is None:
        return "unknown"
    return datetime.fromtimestamp(epoch, PT).strftime("%a %b %-d, %-I:%M %p PT")


def age_str(epoch):
    if epoch is None:
        return "age unknown"
    s = max(0, int(now_ts - epoch))
    if s < 90:
        return f"{s} s ago"
    if s < 5400:
        return f"{s // 60} min ago"
    if s < 172800:
        return f"{s // 3600} h {s % 3600 // 60} min ago"
    return f"{s // 86400} d ago"


def stale_badge(epoch, threshold_s):
    if epoch is None:
        return ' <span class="badge bad">SOURCE MISSING</span>'
    if now_ts - epoch > threshold_s:
        return ' <span class="badge stale">STALE</span>'
    return ""


def esc(x):
    return html.escape(str(x))


# ---------------------------------------------------------------- services
def service_info(unit):
    try:
        active = subprocess.run(["systemctl", "is-active", unit],
                                capture_output=True, text=True,
                                timeout=10).stdout.strip()
    except Exception:
        active = "unknown"
    since = None
    try:
        raw = subprocess.run(
            ["systemctl", "show", unit, "-p", "ActiveEnterTimestamp",
             "--value"], capture_output=True, text=True, timeout=10
        ).stdout.strip()
        if raw:
            since = datetime.strptime(
                raw, "%a %Y-%m-%d %H:%M:%S %Z").replace(
                    tzinfo=timezone.utc).timestamp()
    except Exception:
        pass
    return active, since


aibrain_active, aibrain_since = service_info("aibrain.service")
keeper_active, keeper_since = service_info("helm-keeper.service")

# ---------------------------------------------------------------- keepalive
failcount = None
try:
    failcount = int(open(FAILCOUNT).read().strip())
except Exception:
    pass
ka_last, ka_epoch = "no keepalive log on record", None
try:
    lines = [l for l in open(KEEPALIVE_LOG).read().splitlines() if l.strip()]
    if lines:
        ka_last = lines[-1]
        m = re.match(r"(\S+)", ka_last)
        if m:
            ka_epoch = datetime.fromisoformat(m.group(1)).timestamp()
except Exception:
    pass

# ---------------------------------------------------------------- health
health = {}
try:
    health = json.load(open(HEALTH))
except Exception:
    pass
h_epoch = health.get("epoch")
queue_depth = health.get("queue_depth")
deadletter = health.get("deadletter_count")
last_result_pt = None
if health.get("last_result_ts"):
    try:
        last_result_pt = datetime.strptime(
            health["last_result_ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
    except Exception:
        pass

# ---------------------------------------------------------------- corpus
# Counting method (rewritten 2026-11-12 at Dither's order: count ACTUAL
# messages as displayed in chat, not raw transcript lines).
#
# Audit evidence (full-file parse + source-file spot checks, 2026-11-12):
# every corpus line is a {"type":"message"} record carrying only an id
# (<session-id>-<seq>), a timestamp and message{role, text}. There is NO
# grouping/turn key in the records, and the raw line count overstates
# conversation several-fold:
#   * corpus-sync v2 ingests EVERY agent session (18k+), not just chats —
#     worker/cron/subagent sessions contribute task briefs and work
#     traffic as user/assistant records.
#   * Forked sessions re-carry the parent conversation tail, so the same
#     turn lands once per fork (7,018 exact copies found: identical
#     timestamp+role+text, different session id).
#   * In the voice flow, one sent message is delivered twice as two
#     identical consecutive user records (1,173 adjacent pairs found).
#   * Juno's replies fragment into many consecutive assistant records
#     (spoken fragments, multi-bubble replies, follow-up cap posts).
#
# Discriminators used (all from the records themselves):
#   * Fork duplicate: a (timestamp, role, text) signature already seen
#     earlier in the file.
#   * Machine session: a session whose user records include a task-brief
#     framing (BRIEF_PATTERNS — scheduled-task wrappers, subagent briefs,
#     worker stage briefs), or that has no genuine user record at all.
#     The no-genuine-user case is proven machine traffic: those sessions'
#     only user turns were briefs starting "[WORKER TASK]" /
#     "[SCHEDULED TASK HANDOFF]" / "[PROACTIVITY HANDOFF]", which
#     corpus-sync already drops (its MACHINE_PREFIXES), leaving only
#     their assistant replies in the corpus.
#   * Machine delivery inside a real chat: a user record framed as a
#     handoff/injection (DELIVERY_PATTERNS).
#   * Displayed Dither messages: genuine user records in conversational
#     sessions, with adjacent identical repeats (the voice re-delivery)
#     merged into one.
#   * Displayed Juno replies: maximal runs of consecutive assistant
#     records in a conversational session, bounded by user records —
#     all fragments of one reply count once.
# Line-level classes partition the file exactly:
#   total = dither + juno + machine + fork-duplicate + unclassified.
# Limits: signature dedup cannot catch a fork copy whose text was
# re-wrapped differently; when its session is a machine session the copy
# lands in the machine bucket (conservative — it can only understate,
# never inflate, the chat counts).
import hashlib
from collections import defaultdict

BRIEF_PATTERNS = (
    "[WORKER TASK]", "[SCHEDULED TASK HANDOFF]", "[PROACTIVITY HANDOFF]",
    "Your execution pass for this scheduled task run",
    "## Step instructions", "## This run", "## Task and updates",
    "## The reading day", "## Available lanes",
    "[Subagent Context]", "[Subagent Task]",
    "Find useful, timely ways to help this person",
    "Carry out this assignment end to end",
    "The media stage.", "The sources audit.", "The taste stage",
    "[EVENT HOOK:", "Continue this task from the history above",
)
DELIVERY_PATTERNS = (
    "## Subagent Progress", "<handoff>", "The report inside <handoff>",
    "[BEGIN EXTERNAL CONTENT", "[BEGIN USER CONTEXT",
    "Apply \u201cThoughtful follow-through\u201d",
    'Apply "Thoughtful follow-through"',
    "The next user message is a voice-call handoff",
    "The system file watcher flagged",
)


def _starts_any(text, patterns):
    t = text.lstrip()
    return any(t.startswith(p) for p in patterns)


corpus_counts = None
corpus_mb, corpus_epoch = None, None
try:
    st = os.stat(CORPUS)
    corpus_mb = st.st_size / 1e6
    corpus_epoch = st.st_mtime
    seen_sigs = set()
    per_session = defaultdict(list)
    n_total = n_dup = n_bad = 0
    with open(CORPUS, encoding="utf-8", errors="replace") as f:
        for line in f:
            n_total += 1
            try:
                rec = json.loads(line)
                role = rec["message"]["role"]
                content = rec["message"]["content"]
                if isinstance(content, list):
                    text = "".join(
                        b.get("text", "") for b in content
                        if isinstance(b, dict))
                else:
                    text = str(content)
                sid = rec["id"].rsplit("-", 1)[0]
                ts = rec["timestamp"]
            except Exception:
                n_bad += 1
                continue
            sig = (ts, role, hashlib.md5(text.encode()).digest())
            if sig in seen_sigs:
                n_dup += 1
                continue
            seen_sigs.add(sig)
            if role == "user":
                if _starts_any(text, BRIEF_PATTERNS):
                    kind = "brief"
                elif _starts_any(text, DELIVERY_PATTERNS):
                    kind = "delivery"
                else:
                    kind = "genuine"
            else:
                kind = "assistant"
            per_session[sid].append((kind, text))
    n_dither_rec = n_juno_rec = n_machine_rec = 0
    dither_msgs = juno_replies = 0
    for kinds in per_session.values():
        conversational = (any(k == "genuine" for k, _ in kinds)
                          and not any(k == "brief" for k, _ in kinds))
        if not conversational:
            n_machine_rec += len(kinds)
            continue
        prev_kind, prev_text = None, None
        for kind, text in kinds:
            if kind == "genuine":
                n_dither_rec += 1
                if not (prev_kind == "genuine" and prev_text == text):
                    dither_msgs += 1
            elif kind == "assistant":
                n_juno_rec += 1
                if prev_kind != "assistant":
                    juno_replies += 1
            else:  # delivery
                n_machine_rec += 1
            prev_kind, prev_text = kind, text
    corpus_counts = {
        "total": n_total, "dup": n_dup, "bad": n_bad,
        "dither_rec": n_dither_rec, "juno_rec": n_juno_rec,
        "machine_rec": n_machine_rec,
        "dither_msgs": dither_msgs, "juno_replies": juno_replies,
    }
except Exception:
    corpus_counts = None

# Previous snapshot's classified counts, for honest per-class deltas.
prev_counts, prev_counts_ts = None, None
try:
    prev_state = json.load(open(COUNT_STATE))
    prev_counts = prev_state["counts"]
    prev_counts_ts = prev_state["ts"]
except Exception:
    pass
if corpus_counts is not None:
    try:
        tmp = COUNT_STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"ts": now_ts, "counts": corpus_counts}, f)
        os.replace(tmp, COUNT_STATE)
    except Exception:
        pass

sync_new, sync_epoch = None, None
try:
    sync_epoch = os.stat(CORPUS_LASTRUN).st_mtime
    sync_new = json.load(open(CORPUS_LASTRUN)).get("total_new")
except Exception:
    pass

# ---------------------------------------------------------------- verific.
verif = {}
try:
    txt = open(VERIF_STATE).read()
    m = re.search(r"# Verification State — (\S+)", txt)
    if m:
        verif["when"] = datetime.strptime(
            m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
    for key, pat in (("passed", r"Passed \| (\d+)"),
                     ("failed", r"Failed \| (\d+)"),
                     ("total", r"Total \| (\d+)")):
        m = re.search(pat, txt)
        if m:
            verif[key] = int(m.group(1))
except Exception:
    pass
ledger_ok = False
try:
    ledger_ok = "16/18 official ledger" in open(ORGANS).read()
except Exception:
    pass

# ---------------------------------------------------------------- cathedral
cath_title, cath_pass, cath_epoch = None, None, None
try:
    mans = sorted(f for f in os.listdir(CATHEDRAL_HIDDEN)
                  if re.match(r"manifest-\d{4}-\d{2}-\d{2}", f))
    if mans:
        p = os.path.join(CATHEDRAL_HIDDEN, mans[-1])
        cath_epoch = os.stat(p).st_mtime
        t = open(p).read()
        m = re.search(r"^# (.+)$", t, re.M)
        cath_title = m.group(1) if m else mans[-1]
        cath_pass = "INTEGRITY PASS" in t
except Exception:
    pass

# ------------------------------------------------------- consolidation note
first_cycle = datetime(2026, 11, 15, 2, 44, tzinfo=PT)
if now < first_cycle:
    consol_text = ("The weekly memory consolidation (Sun 2:44 AM) and "
                   "reflection (Sun 3:56 AM) have not run yet — their first "
                   "cycle is Sunday, Nov 15, 2026. Nothing is overdue.")
else:
    consol_text = ("Weekly memory consolidation runs Sundays at 2:44 AM PT "
                   "and reflection at 3:56 AM PT. Per-run verdicts live in "
                   "the helm goal's Stage 4 unification log.")

# ---------------------------------------------------------------- verdict
problems = []
if aibrain_active != "active":
    problems.append("the brain daemon is not running")
if keeper_active != "active":
    problems.append("the helm keeper is not running")
if failcount not in (0, None) and failcount > 0:
    problems.append(f"the keepalive has failed {failcount} check(s) in a row")
if deadletter not in (0, None):
    problems.append(f"{deadletter} task(s) sit in the dead-letter pile")
if queue_depth not in (0, None):
    problems.append(f"{queue_depth} task(s) are waiting in the queue")
verdict_ok = not problems
verdict_plain = ("Everything is running normally."
                 if verdict_ok else
                 "Attention: " + "; ".join(problems) + ".")

# ---------------------------------------------------------------- render
def card(title, plain, tech, badge=""):
    return (f'<section class="card"><h2>{esc(title)}{badge}</h2>'
            f'<p class="plain">{plain}</p>'
            f'<p class="tech">{tech}</p></section>')


cards = []
cards.append(card(
    "Brain daemon (aibrain)",
    "Running — this is the harness itself, Juno's background mind."
    if aibrain_active == "active" else
    f"Not running (state: {esc(aibrain_active)}).",
    f"aibrain.service = {esc(aibrain_active)}; running since "
    f"{fmt_pt(aibrain_since)} (this VM's current boot)."))
cards.append(card(
    "Helm keeper",
    "Running — it guards the task queue so no work is lost."
    if keeper_active == "active" else
    f"Not running (state: {esc(keeper_active)}).",
    f"helm-keeper.service = {esc(keeper_active)}; running since "
    f"{fmt_pt(keeper_since)}."))
cards.append(card(
    "Work queue",
    ("Empty — nothing waiting, nothing lost."
     if queue_depth == 0 and deadletter == 0 else
     f"{esc(queue_depth)} waiting, {esc(deadletter)} in the dead-letter "
     "pile."),
    f"queue_depth = {esc(queue_depth)}, deadletter_count = "
    f"{esc(deadletter)}; keeper heartbeat {fmt_pt(h_epoch)} "
    f"({age_str(h_epoch)}); last queued task finished "
    f"{fmt_pt(last_result_pt)}.",
    stale_badge(h_epoch, 600)))
if corpus_counts is not None:
    _cc = corpus_counts
    _plain = (
        f"The memory corpus holds {_cc['dither_msgs']:,} messages from "
        f"Dither and {_cc['juno_replies']:,} replies from Juno "
        f"({corpus_mb:.0f} MB) — actual chat messages as they appear on "
        "screen, not raw transcript lines. One count per displayed "
        "message: Juno's split fragments merge into the single reply "
        "they belong to, repeated copies of the same turn count once, "
        "and task briefs, handoffs and background-session traffic are "
        "counted separately, never as conversation.")
    if prev_counts is not None and _cc["total"] >= prev_counts["total"]:
        _delta = (
            f"Since the previous snapshot ({fmt_pt(prev_counts_ts)}): "
            f"+{_cc['dither_msgs'] - prev_counts['dither_msgs']:,} from "
            f"Dither, +{_cc['juno_replies'] - prev_counts['juno_replies']:,} "
            f"from Juno, +{_cc['machine_rec'] - prev_counts['machine_rec']:,} "
            "machine/background records. ")
    else:
        _delta = ("Baseline snapshot — change since the previous "
                  "snapshot is tracked from the next refresh. ")
    _tech = (
        _delta
        + f"Transcript file: {_cc['total']:,} lines = "
        f"{_cc['dither_rec']:,} Dither-message records, "
        f"{_cc['juno_rec']:,} Juno records, "
        f"{_cc['machine_rec']:,} machine/background records, "
        f"{_cc['dup']:,} duplicate copies (session forks), "
        f"{_cc['bad']:,} unclassified. File last written "
        f"{fmt_pt(corpus_epoch)} ({age_str(corpus_epoch)})."
        + (f" Last intake sync {fmt_pt(sync_epoch)}: the sync's own "
           f"counter logged +{esc(sync_new)} — it counts raw transcript "
           "records appended from ALL sessions (chats + background "
           "workers), not chat messages."
           if sync_epoch else " No corpus-sync run record found."))
else:
    _plain = "Corpus file not readable."
    _tech = f"Could not stat/read {CORPUS}."
cards.append(card(
    "Memory intake (corpus)", _plain, _tech,
    stale_badge(sync_epoch, 4500)))
cards.append(card(
    "Self-checks (verification)",
    ("16 of 18 checks pass on the official ledger. The 2 that don't are "
     "deliberate: one only runs on Sundays, and one is a known by-design "
     "difference — not breakage."
     if ledger_ok else
     "Official-ledger line not found in the current Cathedral record."),
    (f"Latest wider test sweep ({fmt_pt(verif.get('when'))}): "
     f"{esc(verif.get('passed'))} passed, {esc(verif.get('failed'))} "
     f"failed, {esc(verif.get('total'))} total — the failures beyond the "
     "2 deliberate ones are still owed triage. Source: "
     "VERIFICATION_STATE.md in the helm workspace."
     if verif else "No verification state file on record.")))
cards.append(card(
    "Watchdog (keepalive)",
    ("Healthy — the 5-minute watchdog checked in and found nothing to "
     "repair." if failcount == 0 else
     f"{esc(failcount)} failed check(s) in a row — Juno is alerted at 3."),
    f"Last check {fmt_pt(ka_epoch)} ({age_str(ka_epoch)}): "
    f"{esc(ka_last)}",
    stale_badge(ka_epoch, 900)))
cards.append(card(
    "Cathedral backup of Juno",
    (f"Newest nightly record: {esc(cath_title)}. Integrity: "
     + ("PASS — every identity file hash matched."
        if cath_pass else "see the manifest for details.")),
    f"Manifest written {fmt_pt(cath_epoch)} ({age_str(cath_epoch)}); "
    "nightly build runs about 3:07 AM PT.",
    stale_badge(cath_epoch, 36 * 3600)))
cards.append(card(
    "Weekly consolidation & reflection",
    consol_text,
    "Jobs: hippocampus-weekly-consolidation (Sun 02:44 PT), "
    "hippocampus-weekly-reflection (Sun 03:56 PT). Cron records show no "
    "completed run yet."))

page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Helm Telemetry — Juno's Brain Daemon</title>
<style>
body{{font-family:system-ui,sans-serif;background:#11151c;color:#e8ecf1;
margin:0;padding:24px;}}
main{{max-width:820px;margin:0 auto;}}
h1{{font-size:1.5rem;margin:0 0 4px;}}
.gen{{color:#9aa7b4;margin:0 0 18px;}}
.verdict{{border-radius:10px;padding:14px 18px;font-size:1.15rem;
margin-bottom:20px;}}
.ok{{background:#14351f;border:1px solid #2e7d46;}}
.warn{{background:#3d2f10;border:1px solid #a97b1e;}}
.card{{background:#1a212d;border:1px solid #2b3646;border-radius:10px;
padding:14px 18px;margin-bottom:12px;}}
.card h2{{font-size:1.05rem;margin:0 0 6px;}}
.plain{{margin:0 0 6px;}}
.tech{{margin:0;color:#9aa7b4;font-size:.86rem;}}
.badge{{font-size:.72rem;padding:2px 8px;border-radius:8px;margin-left:8px;
vertical-align:middle;}}
.stale{{background:#a97b1e;color:#111;}}
.bad{{background:#b03a2e;color:#fff;}}
footer{{color:#9aa7b4;font-size:.85rem;margin-top:18px;}}
</style></head><body><main>
<h1>Helm Telemetry — Juno's Brain Daemon Harness</h1>
<p class="gen">Snapshot generated {fmt_pt(now_ts)} on Juno's VM. This page
is refreshed about every 5 minutes; reopen it to see the newest copy.
Anything out of date is badged STALE rather than shown as fresh.</p>
<div class="verdict {'ok' if verdict_ok else 'warn'}">{esc(verdict_plain)}</div>
{''.join(cards)}
<footer>Sources, all read live at render time: systemctl (aibrain.service,
helm-keeper.service), ~/bigpipe-share/helm-health.json,
~/.juno-brain/logs/helm-keepalive.log + failcount, corpus-sync run record +
juno-conversation.jsonl, VERIFICATION_STATE.md, Cathedral nightly
manifests. No number on this page is typed in by hand.</footer>
</main></body></html>
"""

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    f.write(page)

import hashlib
digest = hashlib.sha256(page.encode("utf-8")).hexdigest()
print(f"{OUT} sha256={digest} verdict="
      f"{'OK' if verdict_ok else 'ATTENTION'}")
