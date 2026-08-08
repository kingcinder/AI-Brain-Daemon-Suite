#!/bin/bash
# serve-dashboard.sh — Always-on serve mode for the Brain Dashboard GUI.
#
# Serves $WORKSPACE/brain-dashboard.html on a fixed port with auto-refresh:
# the page polls the server and reloads itself the instant the file changes
# (a job regenerated it), instead of a one-off `python3 -m http.server` that
# shows stale data until you manually refresh.
#
# Built on the suite's own patterns: a stdlib-only Python server
# (scripts/dashboard-server.py) like deep-brain-kernel.py, a scripts/ launcher
# like ci-gate.sh, an optional systemd --user unit like aibrain.service, and a
# tests/test_*.sh that the unit suite picks up automatically.
#
# Usage:
#   scripts/serve-dashboard.sh {start|stop|status|restart|foreground}
#
#   start      Launch the server in the background; builds brain-dashboard.html
#              first if it's missing (via the shared dashboard-builder.sh), so
#              `start` is self-healing on a fresh workspace.
#   stop       Stop the background server.
#   status     Print whether it's running (exit 0 if so).
#   restart    stop + start.
#   foreground Run in the foreground (for debugging, or as the ExecStart of
#              aibrain-dashboard.service).
#
# Env:
#   WORKSPACE                    Defaults to $HOME/.hermes/workspace.
#   DASHBOARD_PORT               Fixed port. Default 8123.
#   DASHBOARD_HOST               Bind address. Default 127.0.0.1 (loopback).
#   DASHBOARD_REFRESH_SECONDS    Auto-refresh poll interval. Default 5.
#   DASHBOARD_PID_FILE           PID file override (default $WORKSPACE/.dashboard-server.pid).
#   DASHBOARD_LOG                Server log override (default $WORKSPACE/.dashboard-server.log).
#
# systemd (user) path — optional, for a boot-started always-on GUI:
#   cp aibrain-dashboard.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now aibrain-dashboard.service
#   journalctl --user -u aibrain-dashboard.service -f

set -euo pipefail

SUITE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
HOST="${DASHBOARD_HOST:-127.0.0.1}"
PORT="${DASHBOARD_PORT:-8123}"
REFRESH_SECONDS="${DASHBOARD_REFRESH_SECONDS:-5}"
PID_FILE="${DASHBOARD_PID_FILE:-$WORKSPACE/.dashboard-server.pid}"
LOG_FILE="${DASHBOARD_LOG:-$WORKSPACE/.dashboard-server.log}"
SERVER="$SUITE_ROOT/scripts/dashboard-server.py"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

running_pid() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ensure_dashboard() {
    if [ ! -f "$WORKSPACE/brain-dashboard.html" ]; then
        echo "serve-dashboard: brain-dashboard.html missing — building via shared dashboard-builder.sh..."
        if [ -x "$SUITE_ROOT/skills/cerebellum-memory/scripts/dashboard-builder.sh" ]; then
            WORKSPACE="$WORKSPACE" "$SUITE_ROOT/skills/cerebellum-memory/scripts/dashboard-builder.sh" >/dev/null 2>&1 || true
        fi
    fi
}

start() {
    command -v python3 >/dev/null 2>&1 || { echo "serve-dashboard: python3 required" >&2; exit 2; }
    [ -f "$SERVER" ] || { echo "serve-dashboard: missing $SERVER" >&2; exit 2; }

    if running_pid; then
        echo "serve-dashboard: already running (pid $(cat "$PID_FILE")) at http://$HOST:$PORT/brain-dashboard.html"
        return 0
    fi

    # If something else already answers on this port (e.g. a leftover ad-hoc
    # `python3 -m http.server`, or another instance we can't track), say so
    # instead of silently failing to bind and timing out below.
    if curl -sf -o /dev/null "http://$HOST:$PORT/brain-dashboard.html" 2>/dev/null; then
        echo "serve-dashboard: port $PORT already serves a dashboard (untracked) — stop that server or pick another DASHBOARD_PORT" >&2
        return 1
    fi

    ensure_dashboard
    mkdir -p "$WORKSPACE"
    # No `rm -f "$PID_FILE"` here: the server writes its own PID file only
    # AFTER a successful bind, so a stale file self-corrects on the next run
    # and a live server's PID file is never clobbered mid-flight.

    # Detach: setsid + full fd redirection so the launcher returns immediately
    # and the server survives the launching shell. The server writes its own
    # PID file once the socket is bound, which we wait for below.
    WORKSPACE="$WORKSPACE" SUITE_ROOT="$SUITE_ROOT" DASHBOARD_HOST="$HOST" \
        DASHBOARD_PORT="$PORT" DASHBOARD_REFRESH_SECONDS="$REFRESH_SECONDS" \
        launch_detached "$(command -v python3)" "$SERVER" --pid-file "$PID_FILE"

    # Wait up to ~10s for the PID file and an HTTP 200.
    for _ in $(seq 1 40); do
        if [ -f "$PID_FILE" ] && curl -sf -o /dev/null "http://$HOST:$PORT/brain-dashboard.html" 2>/dev/null; then
            echo "serve-dashboard: 🧠 Brain Dashboard live at http://$HOST:$PORT/brain-dashboard.html (pid $(cat "$PID_FILE"), auto-refresh ${REFRESH_SECONDS}s)"
            echo "serve-dashboard: log: $LOG_FILE"
            return 0
        fi
        sleep 0.25
    done

    echo "serve-dashboard: server did not come up — see $LOG_FILE" >&2
    stop >/dev/null 2>&1 || true
    return 1
}

stop() {
    if running_pid; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        for _ in $(seq 1 20); do
            running_pid || break
            sleep 0.25
        done
        rm -f "$PID_FILE"
        echo "serve-dashboard: stopped"
    else
        rm -f "$PID_FILE"
        echo "serve-dashboard: not running"
    fi
}

# Portable `setsid`-style detach: util-linux setsid is assumed (the suite
# already targets Linux/systemd), but fall back to plain backgrounding if
# setsid is somehow missing.
launch_detached() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" >>"$LOG_FILE" 2>&1 </dev/null &
    else
        nohup "$@" >>"$LOG_FILE" 2>&1 </dev/null &
    fi
}

status() {
    if running_pid && curl -sf -o /dev/null "http://$HOST:$PORT/brain-dashboard.html" 2>/dev/null; then
        echo "serve-dashboard: RUNNING — http://$HOST:$PORT/brain-dashboard.html (pid $(cat "$PID_FILE"))"
        return 0
    fi
    echo "serve-dashboard: not running"
    return 1
}

foreground() {
    ensure_dashboard
    mkdir -p "$WORKSPACE"
    rm -f "$PID_FILE"
    WORKSPACE="$WORKSPACE" SUITE_ROOT="$SUITE_ROOT" DASHBOARD_HOST="$HOST" \
        DASHBOARD_PORT="$PORT" DASHBOARD_REFRESH_SECONDS="$REFRESH_SECONDS" \
        exec "$(command -v python3)" "$SERVER" --pid-file "$PID_FILE"
}

CMD="${1:-}"
case "$CMD" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    restart) stop >/dev/null; start ;;
    foreground) foreground ;;
    *) usage ;;
esac
