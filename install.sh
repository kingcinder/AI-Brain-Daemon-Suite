#!/bin/bash
# AI Brain Suite — Unified Installer
# Deploys deep-brain-kernel.py (the async scheduler/pressure-supervisor
# engine) + skill packages + V4 core/ (locks, executive, sandbox, …) + aibrain.service.
set -e

# Non-interactive install: AIBRAIN_NONINTERACTIVE=1 or --yes skips the manual pause
# and still enables the service (use for CI / verification).
NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y|--noninteractive) NONINTERACTIVE=1 ;;
  esac
done
if [ "${AIBRAIN_NONINTERACTIVE:-0}" = "1" ]; then
  NONINTERACTIVE=1
fi

echo "--- Step 1: Initializing Workspace ---"
mkdir -p ~/.openclaw/workspace/skills
mkdir -p ~/.openclaw/workspace/core
mkdir -p ~/.config/systemd/user/

echo "--- Step 2: Deploying Artifacts ---"
if [ ! -f "deep-brain-kernel.py" ] || [ ! -f "aibrain.service" ] || [ ! -d "skills" ]; then
    echo "Error: deep-brain-kernel.py, aibrain.service, or skills/ not found in current directory."
    echo "Run this script from inside the extracted suite directory."
    exit 1
fi

cp deep-brain-kernel.py ~/.openclaw/workspace/deep-brain-kernel.py
cp aibrain.service ~/.config/systemd/user/aibrain.service
cp -r skills/. ~/.openclaw/workspace/skills/
# V4.0: foundation + executive function live under core/ (Phase 1–2)
if [ -d "core" ]; then
    cp -r core/. ~/.openclaw/workspace/core/
fi

echo "--- Step 3: Configuring Permissions ---"
chmod +x ~/.openclaw/workspace/deep-brain-kernel.py
find ~/.openclaw/workspace/skills -name "*.sh" -exec chmod +x {} \;
find ~/.openclaw/workspace/core -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

echo "--- Step 4: Host Prerequisites (see SETUP_COMMANDS.md for detail) ---"
echo "Checking PSI (pressure-based deferral)..."
if [ -r /proc/pressure/memory ] && [ -r /proc/pressure/cpu ]; then
    echo "  OK: /proc/pressure/memory and /proc/pressure/cpu are readable."
else
    echo "  WARN: PSI unavailable — the daemon will run fine, but pressure-based"
    echo "        deferral for spawn jobs will be a passive no-op. See SETUP_COMMANDS.md §1."
fi
echo "Checking cgroup v2..."
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
    echo "  OK: cgroup2fs is the active hierarchy."
else
    echo "  WARN: cgroup v2 (unified) doesn't appear active — CPU throttling under"
    echo "        pressure will be disabled, everything else still works. See SETUP_COMMANDS.md §2."
fi
echo "Checking GPU VRAM tooling..."
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "  OK: nvidia-smi found."
elif command -v rocm-smi >/dev/null 2>&1; then
    echo "  OK: rocm-smi found — verify its JSON output matches what the script expects (SETUP_COMMANDS.md §3)."
else
    echo "  WARN: neither nvidia-smi nor rocm-smi found — VRAM-based spawn deferral will"
    echo "        fail open (never blocks). Fine if you don't run local GPU inference."
fi

echo "Checking Python runtime..."
if [ -x /usr/bin/python3 ]; then
    echo "  OK: /usr/bin/python3 is available."
else
    echo "  ERROR: /usr/bin/python3 is missing, but aibrain.service ExecStart is hardcoded"
    echo "         to use that interpreter."
    echo "         Either install python3 there or update the service file before enabling."
    exit 1
fi

echo "--- Step 5: Pre-flight Check ---"
if ! WORKSPACE="$HOME/.openclaw/workspace" python3 ~/.openclaw/workspace/deep-brain-kernel.py --check; then
    echo ""
    echo "Pre-flight check reported problems (see above)."
    echo "Fix them before enabling the service, then re-run this script."
    exit 1
fi

echo ""
echo "!!! ACTION REQUIRED BEFORE ENABLING !!!"
echo "Edit ~/.config/systemd/user/aibrain.service now if any of these apply:"
echo "  (a) Your workspace isn't at \$HOME/.openclaw/workspace, or openclaw/jq/curl/"
echo "      python3/nvidia-smi/rocm-smi live somewhere the PATH= line won't find"
echo "      -> run: which openclaw jq curl python3, and edit Environment=PATH="
echo "  (b) You want to confirm cgroup delegation actually took effect after enabling:"
echo "      -> systemctl --user show -p DelegateControllers aibrain.service"
echo "  (c) Nice=-5 gives this daemon elevated CPU priority over your interactive work"
echo "      -> reconsider this line if the machine feels laggy during spawn jobs"
if [ "$NONINTERACTIVE" -eq 1 ]; then
  echo "(noninteractive) skipping manual pause"
else
  read -r -p "Press Enter once you've reviewed/edited the service file (or to continue as-is): " _
fi

echo "--- Step 6: Systemd Integration ---"
systemctl --user daemon-reload

echo "--- Step 7: Activation ---"
systemctl --user enable --now aibrain.service

echo "--- Step 8: Verification & Status ---"
sleep 1
if systemctl --user is-active --quiet aibrain.service; then
    echo "Installation Successful: Suite is active."
    systemctl --user status aibrain.service --no-pager | head -n 5
    echo ""
    echo "Tail logs with: journalctl --user -u aibrain.service -f"
    echo "Confirm cgroup delegation: systemctl --user show -p DelegateControllers aibrain.service"
    echo "Let it run at least a full day before removing old cron entries, so every"
    echo "once-daily job gets a chance to fire and be observed succeeding — see"
    echo "BRAIN_DAEMON_SCHEDULE.md for the old-cron -> new-daemon mapping."
else
    echo "Installation Error: Suite failed to activate."
    echo "Check: journalctl --user -u aibrain.service -e"
    exit 1
fi
