#!/bin/bash
# shadow-watchdog.sh — Stage 2 shadow-run watchdog. Invoked by the
# goal-owned cron `helm-shadow-watchdog` (~every 10 min) under
# juno-at-the-helm-integration-2, and manually for kill tests.
# Checks: both supervised processes + shadow heartbeat-pulse.log freshness.
# Every check is logged to ~/.juno-brain/logs/watchdog.log.
#
# SUPERVISION OWNERSHIP (Phase 3b, 2026-11-09 refactor): exactly one owner
# at a time, decided by construction — if the systemd units are installed
# (/etc/systemd/system/aibrain-shadow.service present), systemd owns
# liveness and this watchdog only verifies + restarts via systemctl; if
# the units are absent (e.g. after a VM replacement, before the keepalive
# reinstalls them), the shell supervisor owns liveness via the legacy
# identity-checked path. The two paths never act in the same run.
#
# A daemon that is alive but whose pulse has been stale for two
# consecutive checks (>~55 min without a pulse; pulses fire every 30 min)
# is treated as hung and restarted once.
set -u

SHADOW="$HOME/.juno-brain/workspace-shadow"
RUN_DIR="$HOME/.juno-brain/run"
LOG_DIR="$HOME/.juno-brain/logs"
SUP="$HOME/.juno-brain/bin/shadow-supervise.sh"
PULSE="$SHADOW/memory/heartbeat-pulse.log"
STATE="$RUN_DIR/watchdog-state"
WLOG="$LOG_DIR/watchdog.log"
DAEMON_UNIT="aibrain-shadow.service"
KEEPER_UNIT="helm-keeper-shadow.service"
mkdir -p "$RUN_DIR" "$LOG_DIR"

# Single-flight (defect found 2026-11-09, Phase 3b): a cron run and a
# manual run overlapped and both launched restarts, producing duplicate
# daemons. If another watchdog holds the lock, this run stands down.
exec 9>"$RUN_DIR/watchdog.lock"
flock -n 9 || { echo "watchdog already running — standing down"; exit 0; }

ts() { TZ=America/Los_Angeles date +"%Y-%m-%dT%H:%M:%S %Z"; }
now=$(date +%s)

# Phase 1a forensics (2026-11-09, refactor plan): stamp every log line with
# the current boot_id (short form) and record boot changes explicitly, so a
# daemon death can be correlated with a VM replacement from the log alone.
BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
BOOT_STATE="$RUN_DIR/watchdog-boot"
prev_boot=""
[ -f "$BOOT_STATE" ] && prev_boot=$(cat "$BOOT_STATE" 2>/dev/null || echo "")
if [ -n "$prev_boot" ] && [ "$prev_boot" != "$BOOT" ]; then
  echo "[$(ts)] WATCHDOG: BOOT CHANGED prev=$prev_boot now=$BOOT — VM replacement suspected; run-state from the prior boot may be stale" >> "$WLOG"
fi
echo "$BOOT" > "$BOOT_STATE"

proc_start() { # proc_start <pid> → starttime ticks or empty
  [ -r "/proc/$1/stat" ] || return 1
  sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}

identity_ok() { # identity_ok <pidfile> <cmdline-marker> → echoes pid if verified
  # Phase 2 identity rules (2026-11-09): v2 pidfile "<pid> <starttime> <boot>"
  # requires pid + boot + starttime all to match; legacy v1 (bare pid) falls
  # back to a cmdline-marker check. A bare kill -0 is never enough again.
  local f="$1" marker="$2" pid start boot cur_start
  [ -f "$f" ] || return 1
  read -r pid start boot < "$f" || true
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null || return 1
  if [ -n "${start:-}" ] && [ -n "${boot:-}" ]; then
    [ "$boot" = "$BOOT" ] || return 1
    cur_start=$(proc_start "$pid") || return 1
    [ "$cur_start" = "$start" ] || return 1
  else
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$marker" || return 1
  fi
  echo "$pid"; return 0
}

check_one() { # check_one <name> <pidfile> <start-subcommand> <cmdline-marker>
  # Legacy shell-supervisor path — used only when the systemd units are
  # NOT installed (see ownership rule in the header).
  local name="$1" f="$2" sub="$3" marker="$4" pid=""
  if pid=$(identity_ok "$f" "$marker"); then
    echo "ok(pid $pid)"
    return 0
  fi
  [ -f "$f" ] && pid=$(awk '{print $1}' "$f" 2>/dev/null || echo "")
  echo "[$(ts)] WATCHDOG: $name dead (pidfile pid '${pid:-none}') boot=$BOOT — restarting" >> "$WLOG"
  "$SUP" "$sub" >> "$WLOG" 2>&1
  local newpid=""
  newpid=$(identity_ok "$f" "$marker" || true)
  if [ -n "$newpid" ]; then
    echo "[$(ts)] WATCHDOG: $name restarted (pid $newpid) boot=$BOOT" >> "$WLOG"
    echo "RESTARTED(pid $newpid)"
  else
    echo "[$(ts)] WATCHDOG: $name RESTART FAILED boot=$BOOT" >> "$WLOG"
    echo "RESTART-FAILED"
  fi
}

check_unit() { # check_unit <name> <unit> <pidfile>
  # systemd path: the unit owns the process. Verify it is active, take its
  # MainPID, and mirror a v2 identity pidfile into the run dir so the
  # pidfile contract survives for any other reader.
  local name="$1" unit="$2" f="$3" mainpid=""
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    mainpid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo "")
    if [ -n "$mainpid" ] && [ "$mainpid" != "0" ] && kill -0 "$mainpid" 2>/dev/null; then
      echo "$mainpid $(proc_start "$mainpid") $BOOT" > "$f"
      echo "ok(pid $mainpid)"
      return 0
    fi
  fi
  echo "[$(ts)] WATCHDOG: $name unit $unit not healthy (active=$(systemctl is-active "$unit" 2>/dev/null || echo unknown), MainPID=${mainpid:-none}) boot=$BOOT — restarting via systemctl" >> "$WLOG"
  systemctl restart "$unit" >> "$WLOG" 2>&1 || systemctl start "$unit" >> "$WLOG" 2>&1 || true
  sleep 3
  mainpid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo "")
  if systemctl is-active --quiet "$unit" 2>/dev/null && [ -n "$mainpid" ] && [ "$mainpid" != "0" ] && kill -0 "$mainpid" 2>/dev/null; then
    echo "$mainpid $(proc_start "$mainpid") $BOOT" > "$f"
    echo "[$(ts)] WATCHDOG: $name restarted via systemd (pid $mainpid) boot=$BOOT" >> "$WLOG"
    echo "RESTARTED(pid $mainpid)"
  else
    echo "[$(ts)] WATCHDOG: $name RESTART FAILED via systemd boot=$BOOT" >> "$WLOG"
    echo "RESTART-FAILED"
  fi
}

units_installed=0
[ -f "/etc/systemd/system/$DAEMON_UNIT" ] && units_installed=1

# Convergence (Phase 3c race fix, 2026-11-09): if the units were wiped
# (VM replacement) but the canonical copies persist, reinstall them HERE
# rather than falling back to shell supervision — otherwise a watchdog
# run landing before the keepalive cron would start shell instances and
# the keepalive's systemd starts would then duplicate them. Whichever
# job fires first after a replacement converges on systemd ownership.
if [ "$units_installed" != "1" ] && [ -f "$HOME/.juno-brain/systemd/$DAEMON_UNIT" ] && [ -f "$HOME/.juno-brain/systemd/helm-keeper-shadow.service" ]; then
  if cp "$HOME/.juno-brain/systemd/$DAEMON_UNIT" "$HOME/.juno-brain/systemd/helm-keeper-shadow.service" /etc/systemd/system/ 2>>"$WLOG"; then
    systemctl daemon-reload >> "$WLOG" 2>&1 || true
    systemctl enable "$DAEMON_UNIT" helm-keeper-shadow.service >> "$WLOG" 2>&1 || true
    systemctl start "$DAEMON_UNIT" helm-keeper-shadow.service >> "$WLOG" 2>&1 || true
    sleep 3
    [ -f "/etc/systemd/system/$DAEMON_UNIT" ] && units_installed=1
    echo "[$(ts)] WATCHDOG: units were missing — reinstalled from ~/.juno-brain/systemd (converged to systemd ownership) boot=$BOOT" >> "$WLOG"
  else
    echo "[$(ts)] WATCHDOG: unit reinstall failed — falling back to shell supervision this run boot=$BOOT" >> "$WLOG"
  fi
fi

if [ "$units_installed" = "1" ]; then
  daemon_state=$(check_unit daemon "$DAEMON_UNIT" "$RUN_DIR/aibrain-shadow.pid")
  keeper_state=$(check_unit keeper "$KEEPER_UNIT" "$RUN_DIR/helm-keeper-shadow.pid")
else
  daemon_state=$(check_one daemon "$RUN_DIR/aibrain-shadow.pid" start-daemon "workspace-shadow/brain-daemon.sh")
  keeper_state=$(check_one keeper "$RUN_DIR/helm-keeper-shadow.pid" start-keeper "helm-keeper-shadow")
fi

pulse_age="none"
stale_count=0
[ -f "$STATE" ] && stale_count=$(cat "$STATE" 2>/dev/null || echo 0)
case "$stale_count" in ''|*[!0-9]*) stale_count=0 ;; esac
if [ -f "$PULSE" ]; then
  pulse_age=$(( now - $(stat -c %Y "$PULSE") ))
  if [ "$pulse_age" -gt 2700 ]; then
    stale_count=$(( stale_count + 1 ))
    echo "[$(ts)] WATCHDOG: pulse stale ${pulse_age}s (strike $stale_count) boot=$BOOT" >> "$WLOG"
    if [ "$stale_count" -ge 2 ] && [ "${daemon_state#RESTARTED}" = "$daemon_state" ] && [ "${daemon_state#ok}" != "$daemon_state" ]; then
      echo "[$(ts)] WATCHDOG: daemon alive but pulse stale twice — restarting daemon as hung boot=$BOOT" >> "$WLOG"
      if [ "$units_installed" = "1" ]; then
        systemctl restart "$DAEMON_UNIT" >> "$WLOG" 2>&1 || true
        sleep 3
        mainpid=$(systemctl show -p MainPID --value "$DAEMON_UNIT" 2>/dev/null || echo "")
        [ -n "$mainpid" ] && [ "$mainpid" != "0" ] && echo "$mainpid $(proc_start "$mainpid") $BOOT" > "$RUN_DIR/aibrain-shadow.pid"
      else
        "$SUP" stop >/dev/null 2>&1 || true
        # stop kills both; bring both back in order
        "$SUP" start >> "$WLOG" 2>&1
      fi
      stale_count=0
      daemon_state="RESTARTED-HUNG"
    fi
  else
    stale_count=0
  fi
fi
echo "$stale_count" > "$STATE"

echo "[$(ts)] check: daemon=$daemon_state keeper=$keeper_state pulse_age=${pulse_age}s boot=$BOOT owner=$( [ "$units_installed" = "1" ] && echo systemd || echo shell )" >> "$WLOG"
echo "daemon=$daemon_state keeper=$keeper_state pulse_age=${pulse_age}s"
