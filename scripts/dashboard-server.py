#!/usr/bin/env python3
"""dashboard-server.py — Always-on serve mode for the Brain Dashboard.

Serves $WORKSPACE over HTTP and keeps the dashboard live:

  * `/` and `/brain-dashboard.html` — the dashboard with an injected
    auto-refresh script that polls `/__dashboard_mtime` and calls
    `location.reload()` the instant the file changes (a job regenerated it).
    Your selected tab survives reloads because the dashboard keeps it in
    `localStorage` (the builder's own behavior). A second injected line sets
    `window.__DASH_TOKEN`, required to authorize the regenerate endpoint.
  * `/__dashboard_mtime` — `{"mtime": <st_mtime_ns>}` for
    brain-dashboard.html; this is what the injected script polls.
  * `/__fragments` — live fragment inventory from
    `$WORKSPACE/memory/dashboard-fragments/*.json`: id + mtime_ns + size, so
    the page's status bar can detect fragment changes without reloading.
  * `/__daemon` — sanitized daemon status: heartbeat (lastBeat/beatCount/
    lastChosenAction from heartbeat-state.json) + per-job stats and the most
    recent successful job run (from deep-brain-kernel-state.json) + the M7
    autonomy contract mode (memory/self-mod/autonomy-state.json).
  * `POST /__regenerate` — **token-gated** (X-Dashboard-Token must match the
    token injected into the served page). Runs every skill's sync-state.sh
    (falling back to generate-dashboard.sh) across `$SUITE_ROOT/skills/*`
    with WORKSPACE set, then one canonical dashboard-builder.sh assembly —
    the "Regenerate now" button in the dashboard header.
  * everything else — static file served from $WORKSPACE, traversal-guarded
    by the stdlib handler and restricted to browser-renderable assets.

Stdlib-only (http.server, json, subprocess, secrets) — no pip dependencies,
same python3 the daemon already requires.

Env:
  WORKSPACE                 default $HOME/.hermes/workspace
  SUITE_ROOT                repo/deployed root containing skills/ (default:
                            parent of this script's directory)
  DASHBOARD_HOST            default 127.0.0.1 (loopback only)
  DASHBOARD_PORT            default 8123
  DASHBOARD_REFRESH_SECONDS default 5

Run directly for debugging, via `scripts/serve-dashboard.sh` (recommended —
start/stop/status/restart/foreground), or under the optional
`aibrain-dashboard.service` (systemd --user).
"""

import glob
import json
import os
import secrets
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

WORKSPACE = os.path.expanduser(os.environ.get("WORKSPACE", "~/.hermes/workspace"))
SUITE_ROOT = os.environ.get("SUITE_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
HOST = os.environ.get("DASHBOARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("DASHBOARD_PORT", "8123"))
REFRESH_SECONDS = int(os.environ.get("DASHBOARD_REFRESH_SECONDS", "5"))
DASHBOARD = os.path.join(WORKSPACE, "brain-dashboard.html")
FRAGMENTS_DIR = os.path.join(WORKSPACE, "memory", "dashboard-fragments")

# Regenerate is a mutation, so it requires a per-server-session token that is
# injected into the served page. A cross-origin form POST cannot set the
# X-Dashboard-Token header, which gates the endpoint to the dashboard itself.
TOKEN = secrets.token_hex(16)

# The dashboard is self-contained (fragments are inlined at build time), so
# only browser-renderable assets are ever served statically. Everything else
# under $WORKSPACE — .py, .sh, .json, .jsonl, .md, proposal stores,
# provenance, audit logs — is brain internals, never GUI assets, and 404s.
SAFE_EXTENSIONS = (
    ".html", ".htm", ".css", ".js", ".png", ".jpg", ".jpeg",
    ".svg", ".ico", ".webp", ".gif", ".woff", ".woff2", ".ttf",
)

REFRESH_SCRIPT = """<script>
(function () {
  var last = null;
  function poll() {
    fetch('/__dashboard_mtime?t=' + Date.now(), {cache: 'no-store'})
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (last === null) { last = d.mtime; return; }
        if (d.mtime !== last) { location.reload(); }
      })
      .catch(function () {});
  }
  setInterval(poll, %(poll_ms)d);
})();
</script>
<script>window.__DASH_TOKEN = %(token_json)s;</script>
""" % {"poll_ms": REFRESH_SECONDS * 1000, "token_json": json.dumps(TOKEN)}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        # directory=WORKSPACE makes the stdlib static-file path serve only
        # files under the workspace and blocks `..` traversal by default.
        super().__init__(*args, directory=WORKSPACE, **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write("[dashboard-server] %s\n" % (fmt % args))

    # ── helpers ─────────────────────────────────────────────────────────
    def _dashboard_mtime_ns(self):
        try:
            return os.stat(DASHBOARD).st_mtime_ns
        except OSError:
            return 0

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _load_json(self, path):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    # ── payloads ────────────────────────────────────────────────────────
    def _fragments_payload(self):
        frags = []
        if os.path.isdir(FRAGMENTS_DIR):
            for fn in sorted(os.listdir(FRAGMENTS_DIR)):
                if not fn.endswith(".json"):
                    continue
                p = os.path.join(FRAGMENTS_DIR, fn)
                try:
                    st = os.stat(p)
                    frags.append({"id": fn[:-5], "mtime_ns": st.st_mtime_ns, "size": st.st_size})
                except OSError:
                    continue
        last = max((f["mtime_ns"] for f in frags), default=0)
        return {"count": len(frags), "fragments": frags, "lastChanged_ns": last}

    def _daemon_payload(self):
        payload = {"heartbeat": None, "jobs": {"stats": {}, "lastFired": {}, "history": {}}, "summary": {"lastJobRun": None, "unhealthyJobs": []}, "autonomy": None, "lastDeferral": None}
        # M7/M8: the operational autonomy contract (auto_mode vs steward_mode)
        # persisted by deep-brain-kernel.py --autonomy, so the status bar can
        # show the mode + evidence the suite is (or isn't) self-deploying under.
        au = self._load_json(os.path.join(WORKSPACE, "memory", "self-mod", "autonomy-state.json"))
        if isinstance(au, dict) and au.get("mode"):
            payload["autonomy"] = {
                "mode": au.get("mode"),
                # Strict truthiness, matching the history parse below.
                "auto": au.get("auto") is True,
                "computed_at": au.get("computed_at"),
                "evidence": au.get("evidence") or {},
            }
        # Autonomy contract history: every --autonomy computation (appended by
        # deep-brain-kernel.py to autonomy-history.jsonl with a granted/
        # revoked/steady transition tag), so the 🩺 tab can render the contract
        # over time — when and why auto_mode was granted or revoked — not just
        # the latest snapshot. Last 30 entries, oldest first.
        hist_path = os.path.join(WORKSPACE, "memory", "self-mod", "autonomy-history.jsonl")
        hist = []
        try:
            with open(hist_path, encoding="utf-8") as hf:
                for line in hf:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(e, dict):
                        continue
                    hist.append({
                        "ts": e.get("ts"),
                        "mode": e.get("mode"),
                        # Strict truthiness: a hand-written string like
                        # "auto": "false" must not render as granted.
                        "auto": e.get("auto") is True,
                        "transition": e.get("transition", "steady"),
                        "evidence": e.get("evidence") or {},
                    })
        except OSError:
            pass
        payload["autonomyHistory"] = hist[-30:]
        # Autonomy gate provenance: every autonomy.* audit event appended to
        # memory/provenance/events.jsonl by log-provenance.sh event — kernel
        # autonomy.mode.decided computations plus each deferred /
        # deploy_blocked / deploy_allowed pipeline gate outcome. Last 30
        # entries, oldest first — feeds the 🛠 Self-Mod tab's gate timeline
        # (same ledger the fragment bakes at build time).
        prov_path = os.path.join(WORKSPACE, "memory", "provenance", "events.jsonl")
        prov = []
        try:
            with open(prov_path, encoding="utf-8") as pf:
                for line in pf:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(e, dict):
                        continue
                    ev = e.get("event")
                    if not isinstance(ev, str) or not ev.startswith("autonomy."):
                        continue
                    prov.append({
                        "ts": e.get("ts"),
                        "event": ev,
                        "actor": e.get("actor", "unknown"),
                        "detail": e.get("detail") if isinstance(e.get("detail"), dict) else {},
                    })
        except OSError:
            pass
        payload["provenanceEvents"] = prov[-30:]
        # Deferral alert: the weekly self_mod_proposal_cycle defers under
        # steward_mode + full_review (proposal-cycle-tick.sh writes this
        # marker) — so the status bar can tell a steward who expected the
        # cycle to run that it waited instead. Read-only marker; a missing
        # file just means no pending deferral.
        defer = self._load_json(os.path.join(WORKSPACE, "memory", "self-mod", "last-deferral.json"))
        if isinstance(defer, dict) and defer.get("deferred") is True:
            payload["lastDeferral"] = {
                "deferred": True,
                "at": defer.get("at"),
                "autonomy_mode": defer.get("autonomy_mode"),
                "review_mode": defer.get("review_mode"),
                "reason": defer.get("reason"),
            }
        else:
            payload["lastDeferral"] = None
        # M5: per-job success-rate trend from the daemon's per-run outcome
        # ledger (memory/daemon-job-history.jsonl, appended by the kernel on
        # every real job run). Mirrors the verification tab's sparkline.
        hist_path = os.path.join(WORKSPACE, "memory", "daemon-job-history.jsonl")
        by_job = {}
        try:
            with open(hist_path, encoding="utf-8") as hf:
                for line in hf:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    job = e.get("job")
                    if not job:
                        continue
                    by_job.setdefault(job, []).append(1 if e.get("success") else 0)
        except OSError:
            pass
        history = {}
        for job, points in by_job.items():
            recent = points[-10:]  # sparkline window: last 10 real runs
            ok = sum(recent)
            history[job] = {
                "runs": len(recent),  # runs in the 10-run window, not lifetime
                "success_rate": round(ok / len(recent), 3) if recent else 0.0,
                "recent": recent,
            }
        payload["jobs"]["history"] = history
        hb = self._load_json(os.path.join(WORKSPACE, "memory", "heartbeat-state.json"))
        if isinstance(hb, dict):
            payload["heartbeat"] = {
                "lastBeat": hb.get("lastBeat"),
                "beatCount": hb.get("beatCount"),
                "lastChosenAction": hb.get("lastChosenAction"),
                "lastChosenAt": hb.get("lastChosenAt"),
            }
        st = self._load_json(os.path.join(WORKSPACE, "memory", "deep-brain-kernel-state.json"))
        if isinstance(st, dict):
            stats = st.get("jobStats", {}) or {}
            last_fired = st.get("jobLastFired", {}) or {}
            payload["jobs"]["stats"] = stats
            payload["jobs"]["lastFired"] = last_fired
            best = None  # (name, last_success_utc) with the newest timestamp
            for name, s in stats.items():
                ts = (s or {}).get("last_success_utc")
                if ts and (best is None or ts > best[1]):
                    best = (name, ts)
            if best:
                payload["summary"]["lastJobRun"] = {"name": best[0], "at": best[1]}
            payload["summary"]["unhealthyJobs"] = [
                n for n, s in stats.items()
                if (s or {}).get("consecutive_failures", 0) >= 3
            ]
        return payload

    def _regenerate(self):
        """Run every skill's sync-state.sh (or generate-dashboard.sh) with
        WORKSPACE set, then one canonical dashboard-builder.sh assembly."""
        results = {"ran": [], "failed": []}
        env = dict(os.environ)
        env["WORKSPACE"] = WORKSPACE
        skill_dirs = sorted(glob.glob(os.path.join(SUITE_ROOT, "skills", "*")))
        scripts = []
        for sd in skill_dirs:
            if not os.path.isdir(sd):
                continue
            sync = os.path.join(sd, "scripts", "sync-state.sh")
            gen = os.path.join(sd, "scripts", "generate-dashboard.sh")
            # Scripts are invoked via `bash`, so presence (not exec bit)
            # determines runnability — matches how the daemon's tick scripts
            # invoke them.
            if os.path.isfile(sync):
                scripts.append((os.path.basename(sd), sync))
            elif os.path.isfile(gen):
                scripts.append((os.path.basename(sd), gen))
        for name, script in scripts:
            try:
                p = subprocess.run(
                    ["bash", script], env=env, timeout=30,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    check=False,
                )
                if p.returncode == 0:
                    results["ran"].append(name)
                else:
                    results["failed"].append("%s (rc=%d)" % (name, p.returncode))
            except subprocess.TimeoutExpired:
                results["failed"].append(name + " (timeout)")
            except OSError:
                results["failed"].append(name)
        # Final canonical assembly (any single fragment writer's builder call
        # would also assemble, but an explicit call guarantees the full page
        # reflects every fragment that just changed).
        builder = os.path.join(SUITE_ROOT, "skills", "cerebellum-memory", "scripts", "dashboard-builder.sh")
        if os.path.isfile(builder):
            try:
                p = subprocess.run(["bash", builder], env=env, timeout=60,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   check=False)
                if p.returncode != 0:
                    results["failed"].append("dashboard-builder (rc=%d)" % p.returncode)
            except (subprocess.TimeoutExpired, OSError):
                results["failed"].append("dashboard-builder")
        results["mtime_ns"] = self._dashboard_mtime_ns()
        return results

    # ── serving ─────────────────────────────────────────────────────────
    def _serve_dashboard(self):
        if not os.path.isfile(DASHBOARD):
            self.send_error(
                404,
                "brain-dashboard.html not found — run a skill's "
                "generate-dashboard.sh (or scripts/serve-dashboard.sh start, "
                "which builds it via the shared dashboard-builder.sh)",
            )
            return
        with open(DASHBOARD, "rb") as f:
            html = f.read()
        # Inject the auto-refresh script + token before </body>, once per
        # served page. Fall back to appending at EOF if no </body> at all.
        if b"__dashboard_mtime" not in html:
            script = REFRESH_SCRIPT.encode()
            if b"</body>" in html:
                html = html.replace(b"</body>", script + b"</body>", 1)
            else:
                html = html + script
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/__dashboard_mtime":
            self._send_json({"mtime": self._dashboard_mtime_ns(), "file": "brain-dashboard.html"})
            return
        if path == "/__fragments":
            self._send_json(self._fragments_payload())
            return
        if path == "/__daemon":
            self._send_json(self._daemon_payload())
            return
        if path in ("/", "/brain-dashboard.html", "/index.html"):
            self._serve_dashboard()
            return
        # Static fallback: safe browser assets only (see SAFE_EXTENSIONS).
        ext = os.path.splitext(path)[1].lower()
        if ext not in SAFE_EXTENSIONS:
            self.send_error(404, "not a served GUI asset (extension blocked)")
            return
        super().do_GET()

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/__regenerate":
            if self.headers.get("X-Dashboard-Token") != TOKEN:
                self._send_json({"error": "forbidden — token required"}, status=403)
                return
            self._send_json(self._regenerate())
            return
        self.send_error(405, "method not allowed")


def main():
    pid_file = None
    args = sys.argv[1:]
    if args and args[0] == "--pid-file" and len(args) > 1:
        pid_file = args[1]

    os.makedirs(WORKSPACE, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    if pid_file:
        with open(pid_file, "w") as f:
            f.write(str(os.getpid()))
    print(
        "Brain Dashboard live at http://%s:%d/brain-dashboard.html "
        "(auto-refresh every %ds)" % (HOST, PORT, REFRESH_SECONDS),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if pid_file and os.path.exists(pid_file):
            os.remove(pid_file)


if __name__ == "__main__":
    main()
