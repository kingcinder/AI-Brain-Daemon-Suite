#!/bin/bash
# AI Brain Suite — Unified Uninstaller
# Inverse of install.sh: stops and disables aibrain.service, removes the
# deployed workspace + systemd unit + Hermes skills.external_dirs entry, and
# restores the pre-install state from the .bak-aibrain-install backups the
# installer created — where a backup exists, the pre-install artifact comes
# back; where none existed (fresh install), the artifact is removed outright.
#
# Mirrors install.sh's discipline exactly:
#   - set -euo pipefail; --help; unknown args fail fast; HOME guard
#   - single-instance flock on the SAME lock file (~/.hermes/.aibrain-install.lock)
#     so a concurrent install/uninstall can't race a live deploy
#   - back up the current (installed) state before modifying, and restore it
#     via an ERR trap if anything fails mid-uninstall
#   - TTY-safe confirmation (refuses without a TTY unless --yes is passed);
#     never hangs CI
#   - graceful systemd-user-session detection; removal-marker checks so we
#     never delete a foreign workspace/unit
set -euo pipefail

# ── CLI / env ──────────────────────────────────────────────────────────────
# Non-interactive uninstall: AIBRAIN_NONINTERACTIVE=1 or --yes skips the
# confirmation prompt (use for CI / scripts).
NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y|--noninteractive) NONINTERACTIVE=1 ;;
    --help|-h)
        cat <<'EOF'
AI Brain Suite uninstaller

Usage: ./uninstall.sh [--yes|-y|--noninteractive] [--help|-h]

  --yes | -y | --noninteractive
      Skip the confirmation prompt (fully unattended).
      Same as AIBRAIN_NONINTERACTIVE=1. Required when stdin is not a TTY.

  --help | -h
      Show this help and exit.

Stops and disables aibrain.service, removes ~/.hermes/workspace, the systemd
unit, and the Hermes skills.external_dirs entry, and restores the pre-install
.bak-aibrain-install backups where the installer created them. Shares
install.sh's single-instance lock and backup/rollback discipline.
EOF
        exit 0 ;;
    *)
        echo "Unknown argument: $arg (see --help)" >&2
        exit 2 ;;
  esac
done
if [ "${AIBRAIN_NONINTERACTIVE:-0}" = "1" ]; then
  NONINTERACTIVE=1
fi

[ -n "${HOME:-}" ] || { echo "Error: HOME is not set." >&2; exit 1; }

# ── Paths (mirror install.sh) ──────────────────────────────────────────────
WS="$HOME/.hermes/workspace"
BK="$HOME/.hermes/workspace.bak-aibrain-install"        # pre-install workspace (installer)
UN_BK="$HOME/.hermes/workspace.bak-aibrain-uninstall"   # installed workspace, moved aside here
UNIT_FILE="$HOME/.config/systemd/user/aibrain.service"
UNIT_BK="$UNIT_FILE.bak-aibrain-install"                # pre-install unit (installer)
UN_UNIT="$UNIT_FILE.bak-aibrain-uninstall"              # installed unit, moved aside here
HERMES_CONFIG="$HOME/.hermes/config.yaml"
CFG_BK="$HERMES_CONFIG.bak-aibrain-install"             # pre-merge config (installer)
UN_CFG="$HERMES_CONFIG.bak-aibrain-uninstall"           # pre-uninstall config, copied aside here
EXT_DIR="~/.hermes/workspace/skills"                    # the exact entry install.sh writes

ROLLED_BACK=0
STOPPED=0

# systemd --user is present iff the private socket exists under $XDG_RUNTIME_DIR
# (same check as install.sh).
systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -n "${XDG_RUNTIME_DIR:-}" ] || return 1
    [ -S "$XDG_RUNTIME_DIR/systemd/private" ] || return 1
    return 0
}

# Undo a partial uninstall: restore the installed state we moved/copied aside.
# Idempotent. `exit` (intentional paths: nothing-to-uninstall, refusal) does
# NOT fire the ERR trap, so only genuine mid-uninstall failures roll back.
rollback() {
    [ "$ROLLED_BACK" -eq 1 ] && return 0
    ROLLED_BACK=1
    echo ""
    echo "--- Rolling back uninstall ---"
    if [ -d "$UN_BK" ]; then
        rm -rf "$WS" 2>/dev/null || true
        mv "$UN_BK" "$WS" 2>/dev/null || true
        echo "  restored workspace from $UN_BK"
    fi
    if [ -f "$UN_UNIT" ]; then
        rm -f "$UNIT_FILE" 2>/dev/null || true
        mv "$UN_UNIT" "$UNIT_FILE" 2>/dev/null || true
        echo "  restored unit from $UN_UNIT"
    fi
    if [ -f "$UN_CFG" ]; then
        cp "$UN_CFG" "$HERMES_CONFIG" 2>/dev/null || true
        echo "  restored Hermes config from $UN_CFG"
    fi
    if [ "$STOPPED" -eq 1 ] && systemd_available; then
        systemctl --user enable --now aibrain.service 2>/dev/null || true
        echo "  re-enabled aibrain.service"
    fi
    echo "Rollback complete."
}
trap rollback ERR

# ── Is anything installed? ─────────────────────────────────────────────────
HAS_INSTALL=0
[ -d "$WS" ] && HAS_INSTALL=1
[ -f "$UNIT_FILE" ] && HAS_INSTALL=1
if [ -f "$HERMES_CONFIG" ] && grep -qF "$EXT_DIR" "$HERMES_CONFIG"; then
    HAS_INSTALL=1
fi
if [ "$HAS_INSTALL" -eq 0 ]; then
    echo "Nothing to uninstall — no workspace, unit, or Hermes skills entry found."
    echo "(Leftover .bak-aibrain-install backups, if any, are left untouched.)"
    exit 0
fi

# ── Single-instance guard (same lock file as install.sh) ──────────────────
mkdir -p "$HOME/.hermes" "$HOME/.config/systemd/user"
exec 9>"$HOME/.hermes/.aibrain-install.lock"
if ! flock -n 9; then
    echo "Error: another install/uninstall is already running (lock ~/.hermes/.aibrain-install.lock is held)." >&2
    exit 1
fi

# ── Confirmation (TTY-safe: never hangs CI, never auto-nukes from a pipe) ──
if [ "$NONINTERACTIVE" -eq 0 ] && [ -t 0 ]; then
    echo "This will stop and disable aibrain.service, remove:"
    echo "  - workspace:  $WS"
    echo "  - unit:       $UNIT_FILE"
    echo "  - Hermes skills entry in $HERMES_CONFIG"
    echo "and restore the pre-install .bak-aibrain-install backups where they exist."
    read -r -p "Type 'yes' to confirm uninstall: " ans || true
    if [ "${ans:-}" != "yes" ]; then
        echo "Aborted — nothing was changed."
        exit 0
    fi
elif [ "$NONINTERACTIVE" -eq 0 ]; then
    echo "Error: no TTY and no --yes — refusing to uninstall without confirmation." >&2
    echo "Re-run with --yes (or AIBRAIN_NONINTERACTIVE=1) to confirm." >&2
    exit 1
fi

echo ""
echo "--- Step 1: Stopping & Disabling Service ---"
if systemd_available; then
    if systemctl --user is-active --quiet aibrain.service 2>/dev/null; then
        systemctl --user stop aibrain.service || true
        STOPPED=1
        echo "  stopped aibrain.service"
    else
        echo "  aibrain.service not active — nothing to stop"
    fi
    systemctl --user disable aibrain.service 2>/dev/null || true
    echo "  disabled aibrain.service"
else
    echo "  WARN: no systemd --user session detected (container/WSL) — nothing to stop here;"
    echo "        the unit file is still removed below."
fi

echo "--- Step 2: Removing Systemd Unit ---"
if [ -f "$UNIT_FILE" ]; then
    if grep -q "deep-brain-kernel" "$UNIT_FILE"; then
        mv "$UNIT_FILE" "$UN_UNIT"
        if [ -f "$UNIT_BK" ]; then
            mv "$UNIT_BK" "$UNIT_FILE"
            echo "  restored pre-install unit from $UNIT_BK"
        else
            echo "  removed aibrain.service (no pre-install unit to restore)"
        fi
    else
        echo "  WARN: $UNIT_FILE doesn't reference deep-brain-kernel — not our unit; leaving it."
    fi
else
    echo "  no unit at $UNIT_FILE — nothing to remove"
fi

echo "--- Step 2.5: Removing Per-Skill State ---"
# Initiative 9: run every skill's `install.sh --uninstall --yes` so each skill
# removes exactly the state files its manifest declares — before the workspace
# itself is moved aside. Skipped gracefully when the chain isn't deployed.
if [ -d "$WS/skills" ] && [ -x "$WS/core/skill-init/cleanup-all-skills.sh" ]; then
    WORKSPACE="$WS" bash "$WS/core/skill-init/cleanup-all-skills.sh" --workspace "$WS" --yes || \
        echo "  WARN: per-skill cleanup reported failures (workspace removal will still proceed)."
else
    echo "  skipped (cleanup chain not deployed at $WS/core/skill-init/)"
fi

echo "--- Step 3: Removing Workspace ---"
if [ -d "$WS" ]; then
    if [ -f "$WS/deep-brain-kernel.py" ]; then
        mv "$WS" "$UN_BK"
        if [ -d "$BK" ]; then
            mv "$BK" "$WS"
            echo "  restored pre-install workspace from $BK"
        else
            echo "  removed workspace (no pre-install workspace to restore)"
        fi
    else
        echo "  WARN: $WS has no deep-brain-kernel.py — not the suite workspace; leaving it."
    fi
else
    echo "  no workspace at $WS — nothing to remove"
fi

echo "--- Step 4: Removing Hermes Skills Entry ---"
if [ -f "$HERMES_CONFIG" ]; then
    cp "$HERMES_CONFIG" "$UN_CFG"
    if [ -f "$CFG_BK" ]; then
        # The installer merged the entry and backed up the pre-merge config —
        # restoring it fully reverts the merge (entry + any incidental change).
        mv "$CFG_BK" "$HERMES_CONFIG"
        echo "  restored pre-install $HERMES_CONFIG from $CFG_BK"
    else
        # No installer backup (entry pre-existed or merge was a no-op) — surgically
        # remove the external_dirs item, then drop now-empty keys, mirroring the
        # installer's conservative block-style merge in reverse.
        if RESULT=$(python3 - "$HERMES_CONFIG" "$EXT_DIR" <<'PY'
import sys, pathlib, re

cfg_path, ext = sys.argv[1], sys.argv[2]
cfg = pathlib.Path(cfg_path)
lines = cfg.read_text().splitlines()

# 1) Drop the exact external_dirs item pointing at the suite (any indent).
out = []
removed = False
for line in lines:
    if not removed and re.match(r'^\s*-\s*' + re.escape(ext) + r'\s*$', line):
        removed = True
        continue
    out.append(line)

if removed:
    # 2) Drop an external_dirs: key left with no items beneath it.
    clean = []
    i = 0
    while i < len(out):
        line = out[i]
        if re.match(r'^\s{2}external_dirs:\s*$', line):
            j = i + 1
            while j < len(out) and re.match(r'^\s*- ', out[j]):
                j += 1
            if j == i + 1:  # no items remain -> empty key
                i += 1
                continue
        clean.append(line)
        i += 1
    out = clean
    # 3) Drop a bare skills: key left with no children.
    clean = []
    i = 0
    while i < len(out):
        line = out[i]
        if re.match(r'^skills:\s*$', line):
            j = i + 1
            while j < len(out) and re.match(r'^\s+\S', out[j]):
                j += 1
            if j == i + 1:  # no children remain -> empty key
                i += 1
                continue
        clean.append(line)
        i += 1
    out = clean
    # 4) Trim a trailing blank line our earlier append may have left.
    while out and out[-1].strip() == "":
        out.pop()

cfg.write_text("\n".join(out) + "\n")
print("removed" if removed else "absent")
PY
); then
            :
        else
            RESULT="merge-failed"
        fi
        case "$RESULT" in
            removed) echo "  removed skills.external_dirs -> $EXT_DIR from $HERMES_CONFIG" ;;
            absent)  echo "  no skills.external_dirs entry for $EXT_DIR in $HERMES_CONFIG — already clean" ;;
            *)       echo "  WARN: config edit produced an unexpected result ($RESULT) — see HERMES_COMPATIBILITY.md Option B." ;;
        esac
    fi
else
    echo "  no $HERMES_CONFIG — nothing to remove"
fi

if systemd_available; then
    systemctl --user daemon-reload || true
fi

# The moved-aside installed state was only kept for rollback safety — now that
# the uninstall succeeded, drop it (the pre-install .bak-aibrain-install
# backups were already restored above, where they existed).
rm -rf "$UN_BK" 2>/dev/null || true
rm -f "$UN_UNIT" 2>/dev/null || true

echo ""
echo "--- Uninstall Complete ---"
if [ -f "$UN_CFG" ]; then
    echo "  Note: pre-uninstall $HERMES_CONFIG preserved at $UN_CFG (remove with rm -f)."
fi
