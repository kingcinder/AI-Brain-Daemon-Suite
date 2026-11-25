#!/bin/bash
# helm-keepalive.sh — deterministic, idempotent repair for the helm REAL
# instance (Stage 3 cutover, 2026-11-10). Replaces the agent-reasoned
# helm-keepalive cron body (2026-11-12): no judgment in here — check,
# repair only what is missing/inactive, verify, log one terse line.
#
# The VM's /etc layer is wiped on every replacement (~2h); home persists.
# Canonical units: ~/.juno-brain/systemd/. bc is bundled under
# ~/.juno-brain/pkg-root/usr/bin (extracted once with dpkg -x from the
# cached .deb) and the units' PATH points there first, so no dpkg -i
# is needed after a replacement; dpkg remains only as a fallback below.
#
# Exit: 0 = healthy or repaired-and-verified. Non-zero = verification
# still failing after repair. Consecutive-failure count is kept in
# ~/.juno-brain/logs/helm-keepalive.failcount for the cron's 3-strike
# reporting rule.

set -u

JB="${JB_HOME:-$HOME/.juno-brain}"
[ -d "$JB" ] || JB="/home/hatch/.juno-brain"
CANON="$JB/systemd"
INSTALLED="/etc/systemd/system"
LOGDIR="$JB/logs"
LOG="$LOGDIR/helm-keepalive.log"
FAILCOUNT_FILE="$LOGDIR/helm-keepalive.failcount"
UNITS="aibrain.service helm-keeper.service"
BUNDLED_BC="$JB/pkg-root/usr/bin/bc"

mkdir -p "$LOGDIR"

ts() { date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }

# Serialize overlapping runs; a second concurrent run is a no-op.
exec 9>"$LOGDIR/helm-keepalive.lock"
flock -n 9 || exit 0

bc_ok() {
    if [ -x "$BUNDLED_BC" ] && "$BUNDLED_BC" --version >/dev/null 2>&1; then
        return 0
    fi
    command -v bc >/dev/null 2>&1 && bc --version >/dev/null 2>&1
}

repairs=""

# --- bc -----------------------------------------------------------------
if ! bc_ok; then
    deb="$(ls "$JB"/pkg-cache/bc_*.deb 2>/dev/null | head -1)"
    if [ -n "$deb" ]; then
        # First restore the bundled copy (persistent, no system change).
        dpkg -x "$deb" "$JB/pkg-root" >/dev/null 2>&1
        if bc_ok; then
            repairs="$repairs bc-reextracted"
        else
            # Fallback: system-level install, as the old cron body did.
            dpkg -i "$deb" >/dev/null 2>&1
            bc_ok && repairs="$repairs bc-dpkg-installed"
        fi
    fi
fi

# --- unit files -----------------------------------------------------------
units_changed=0
for u in $UNITS; do
    if [ ! -f "$INSTALLED/$u" ] || ! cmp -s "$CANON/$u" "$INSTALLED/$u"; then
        units_changed=1
        break
    fi
done

if [ "$units_changed" = "1" ]; then
    if cp "$CANON/aibrain.service" "$CANON/helm-keeper.service" "$INSTALLED/" \
        && systemctl daemon-reload >/dev/null 2>&1 \
        && systemctl enable $UNITS >/dev/null 2>&1; then
        repairs="$repairs units-reinstalled"
    fi
fi

# --- services ---------------------------------------------------------------
for u in $UNITS; do
    if ! systemctl is-active --quiet "$u"; then
        systemctl start "$u" >/dev/null 2>&1
        repairs="$repairs started:$u"
    fi
done

# --- verify -------------------------------------------------------------------
fail=""
systemctl is-active --quiet aibrain.service    || fail="$fail aibrain-inactive"
systemctl is-active --quiet helm-keeper.service || fail="$fail helm-keeper-inactive"
for u in $UNITS; do
    cmp -s "$CANON/$u" "$INSTALLED/$u" || fail="$fail unit-drift:$u"
done
bc_ok || fail="$fail bc-missing"

if [ -z "$fail" ]; then
    echo 0 > "$FAILCOUNT_FILE"
    if [ -n "$repairs" ]; then
        echo "$(ts) helm-keepalive: repaired:$repairs; aibrain=active helm-keeper=active bc=ok" >> "$LOG"
    else
        echo "$(ts) helm-keepalive: ok healthy" >> "$LOG"
    fi
    exit 0
fi

n=0
[ -f "$FAILCOUNT_FILE" ] && n="$(cat "$FAILCOUNT_FILE" 2>/dev/null || echo 0)"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
echo "$n" > "$FAILCOUNT_FILE"
echo "$(ts) helm-keepalive: FAIL after repair:$repairs; failures:$fail; consecutive=$n" >> "$LOG"
echo "helm-keepalive: verification failed:$fail (consecutive=$n)" >&2
exit 1
