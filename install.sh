#!/bin/bash
# AI Brain Suite — Unified Installer
# Deploys deep-brain-kernel.py (the async scheduler/pressure-supervisor
# engine) + skill packages + V4 core/ (locks, executive, sandbox, …) + aibrain.service.
#
# Hardened installer:
#   - set -euo pipefail; resolves its own directory so it runs from anywhere
#   - --help; unknown args fail fast
#   - single-instance flock so concurrent installs can't corrupt the deploy
#   - backs up the current workspace + unit and restores them via an ERR trap
#     if anything fails mid-deploy
#   - replace-style deploy of the five shipped targets (skills/, core/, tests/,
#     scripts/, kernel) so stale files never survive; the daemon's runtime state
#     dirs (e.g. $WS/memory/) are never touched
#   - pre-flight --check gates the deploy; skill-file-count sanity check
#   - TTY-safe conditional pause (never hangs CI); systemd-user-session
#     detection so containers/WSL degrade gracefully instead of failing late
#   - --refresh re-deploys the five shipped targets from the repo into the
#     existing workspace and restarts the daemon — no config change, no
#     re-enable (use after pulling new code, e.g. a new daemon job)
set -euo pipefail

# ── CLI / env ──────────────────────────────────────────────────────────────
# Non-interactive install: AIBRAIN_NONINTERACTIVE=1 or --yes skips the manual
# pause and still enables the service (use for CI / verification).
NONINTERACTIVE=0
REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y|--noninteractive) NONINTERACTIVE=1 ;;
    --refresh) REFRESH=1 ;;
    --help|-h)
        cat <<'EOF'
AI Brain Suite installer

Usage: ./install.sh [--refresh] [--yes|-y|--noninteractive] [--help|-h]

  --refresh
      Re-deploy the suite from this repo into the existing
      ~/.hermes/workspace and restart aibrain.service — without touching
      the Hermes config, the unit file, or re-enabling. Use after pulling
      new repo code (e.g. a new daemon job like neuromod_update) so the
      live daemon picks it up in one command. Requires an existing install.

  --yes | -y | --noninteractive
      Fully unattended: no interactive pause; still enables the service.
      Same as AIBRAIN_NONINTERACTIVE=1.

  --help | -h
      Show this help and exit.

Deploys deep-brain-kernel.py, skills/, core/, tests/ and scripts/ into
~/.hermes/workspace/, patches aibrain.service's Environment=PATH=, registers
the skills with Hermes (Option B), and enables the systemd --user service.
The previous install is preserved at ~/.hermes/workspace.bak-aibrain-install
and restored automatically if the install fails.

Remove the suite later with ./uninstall.sh (restores the pre-install
.bak-aibrain-install backups where they exist).
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

# Run from the suite directory regardless of how/where we were invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Validate the suite layout up front — fail before we touch anything.
if [ ! -f "deep-brain-kernel.py" ] || [ ! -f "aibrain.service" ] || [ ! -d "skills" ]; then
    echo "Error: deep-brain-kernel.py, aibrain.service, or skills/ not found in current directory."
    echo "Run this script from inside the extracted suite directory."
    exit 1
fi

# jq is required by the dashboard builder, manifest validation, and daemon
# job dispatch.  Fail fast here so the user gets one clear message instead of
# scattered mid-test failures.
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not found on PATH."
    echo "Install it via:  sudo apt install jq   OR   brew install jq"
    exit 1
fi

[ -n "${HOME:-}" ] || { echo "Error: HOME is not set." >&2; exit 1; }

# ── Paths / rollback state ──────────────────────────────────────────────────
WS="$HOME/.hermes/workspace"
BK="$HOME/.hermes/workspace.bak-aibrain-install"
UNIT_FILE="$HOME/.config/systemd/user/aibrain.service"
UNIT_BK="$UNIT_FILE.bak-aibrain-install"

ROLLED_BACK=0
BK_CREATED=0
UNIT_BK_CREATED=0
WS_PREEXISTED=0
SYSTEMD_OK=0
[ -d "$WS" ] && WS_PREEXISTED=1

# Restore the previous install if anything fails mid-deploy. Idempotent.
# Intentional `exit 1` paths that should NOT roll back (e.g. the service
# failing to activate — the deploy is valid, the environment is not) call
# `exit` directly, which does not fire the ERR trap.
rollback() {
    [ "$ROLLED_BACK" -eq 1 ] && return 0
    ROLLED_BACK=1
    echo ""
    echo "--- Rolling back to the previous install ---"
    if [ "$BK_CREATED" -eq 1 ] && [ -d "$BK" ]; then
        rm -rf "$WS"
        mv "$BK" "$WS"
        echo "  restored workspace from $BK"
    elif [ "$WS_PREEXISTED" -eq 0 ]; then
        rm -rf "$WS"
        echo "  removed partial workspace (no previous install to restore)"
    else
        echo "  existing workspace left as-is (backup was not created)"
    fi
    if [ "$UNIT_BK_CREATED" -eq 1 ] && [ -f "$UNIT_BK" ]; then
        cp "$UNIT_BK" "$UNIT_FILE"
        echo "  restored aibrain.service from $UNIT_BK"
    fi
    echo "Rollback complete."
}
trap rollback ERR

# ── deploy_workspace: replace-style deploy of the five shipped targets ─────
# Wipe and re-copy only the five shipped targets (deep-brain-kernel.py,
# skills/, core/, tests/, scripts/) so no stale files survive from older
# versions. Everything the daemon writes at runtime (e.g. $WS/memory/,
# $WS/state/) is never touched. Shared by the install path (Step 2+3) and
# --refresh so the shipped-target list can't drift between the two.
deploy_workspace() {
    rm -rf "$WS/deep-brain-kernel.py" "$WS/skills" "$WS/core" "$WS/tests" "$WS/scripts"
    cp deep-brain-kernel.py "$WS/deep-brain-kernel.py"
    cp -r skills "$WS/skills"
    # V4.0: foundation + executive function live under core/ (Phase 1–2)
    if [ -d core ]; then
        cp -r core "$WS/core"
    fi
    # Verification region: the declared-test harnesses ship with the suite so
    # verification-memory can run them in a deployed workspace, not just the repo.
    if [ -d tests ]; then
        cp -r tests "$WS/tests"
    fi
    # Dashboard + verification scripts (serve-dashboard.sh, dashboard-server.py,
    # ci-gate.sh, deep-verify.sh): the deployed tests reference $ROOT/scripts/*,
    # so shipping scripts/ keeps the deployed tree self-consistent (the dashboard
    # tests resolve ROOT relative to the test file and call serve-dashboard.sh).
    if [ -d scripts ]; then
        cp -r scripts "$WS/scripts"
        # Python bytecode cache is runtime-generated, not source — keep the
        # deployed tree pristine.
        rm -rf "$WS/scripts/__pycache__"
    fi
    chmod +x "$WS/deep-brain-kernel.py"
    find "$WS/skills" -name "*.sh" -exec chmod +x {} \;
    find "$WS/core" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    find "$WS/tests" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
}

# ── systemd --user availability ─────────────────────────────────────────────
# A live user manager is present iff the private socket exists under
# $XDG_RUNTIME_DIR. Containers, WSL, and not-yet-logged-in sessions lack it;
# there the deploy still completes and the user enables the service later.
# Defined here (not near Step 6) because --refresh below also uses it.
systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -n "${XDG_RUNTIME_DIR:-}" ] || return 1
    [ -S "$XDG_RUNTIME_DIR/systemd/private" ] || return 1
    return 0
}

# ── --refresh mode ──────────────────────────────────────────────────────────
# Re-deploy the five shipped targets from this repo into the existing
# workspace and restart the daemon — no Hermes config merge, no unit-file
# copy/PATH patch, no re-enable. Use after pulling new repo code (e.g. a new
# daemon job like neuromod_update) so the live daemon picks it up in one
# command. Same flock + backup/rollback discipline as install.
if [ "${REFRESH:-0}" = "1" ]; then
    if [ ! -d "$WS" ]; then
        echo "Error: no workspace at $WS — run ./install.sh first." >&2
        exit 1
    fi
    echo "--- Refresh: Re-deploying suite into $WS ---"
    # Same single-instance guard as install.
    exec 9>"$HOME/.hermes/.aibrain-install.lock"
    if ! flock -n 9; then
        echo "Error: another install/refresh is already running (lock held)." >&2
        exit 1
    fi
    # Back up the current workspace so a mid-deploy failure can roll back.
    rm -rf "$BK"
    cp -a "$WS" "$BK"
    BK_CREATED=1
    echo "  backed up existing workspace -> $BK"
    # Replace-style deploy of the five shipped targets only (shared helper —
    # the unit file and the Hermes config are deliberately untouched).
    deploy_workspace
    # Gate the refresh on the same pre-flight check the install uses.
    echo "--- Refresh: Pre-flight --check ---"
    if ! WORKSPACE="$WS" python3 "$WS/deep-brain-kernel.py" --check; then
        echo ""
        echo "Refresh pre-flight check reported problems (see above)." >&2
        echo "Rolling back to the previous workspace." >&2
        rollback
        exit 1
    fi
    # Deploy-count sanity (same as install).
    REPO_SKILL_FILES=$(find skills -type f | wc -l)
    DEPLOYED_SKILL_FILES=$(find "$WS/skills" -type f | wc -l)
    if [ "$REPO_SKILL_FILES" -eq "$DEPLOYED_SKILL_FILES" ]; then
        echo "  OK: $DEPLOYED_SKILL_FILES skill files deployed (matches repo)."
    else
        echo "  WARN: skill file count mismatch (repo $REPO_SKILL_FILES vs deployed $DEPLOYED_SKILL_FILES)."
    fi
    # Restart the running daemon onto the new code (no enable, no unit edit).
    if systemd_available; then
        echo "--- Refresh: Restarting aibrain.service ---"
        systemctl --user restart aibrain.service
        sleep 1
        if systemctl --user is-active --quiet aibrain.service; then
            echo "Refresh complete: workspace re-deployed and daemon restarted."
            systemctl --user status aibrain.service --no-pager | head -n 5 || true
            echo "Tail logs with: journalctl --user -u aibrain.service -f"
        else
            echo "Refresh error: aibrain.service failed to restart." >&2
            echo "Check: journalctl --user -u aibrain.service -e" >&2
            exit 1
        fi
    else
        echo "--- Refresh: no systemd --user session detected (container/WSL) ---"
        echo "  Workspace re-deployed. Restart the daemon manually once a user session exists:"
        echo "    systemctl --user restart aibrain.service"
    fi
    if [ -d "$BK" ]; then
        echo "Note: previous workspace preserved at $BK — remove it with: rm -rf $BK"
    fi
    exit 0
fi

echo "--- Step 1: Initializing Workspace ---"
mkdir -p "$WS/skills"
mkdir -p "$WS/core"
mkdir -p "$HOME/.config/systemd/user/"

# Single-instance guard: only one install at a time may touch the workspace.
# The lock fd stays open for the whole script and releases on exit.
exec 9>"$HOME/.hermes/.aibrain-install.lock"
if ! flock -n 9; then
    echo "Error: another install is already running (lock ~/.hermes/.aibrain-install.lock is held)." >&2
    exit 1
fi

# Back up the current state so a mid-deploy failure can be rolled back.
# Gate on WS_PREEXISTED (captured BEFORE Step 1's mkdir -p below creates the
# workspace): a fresh install must not back up its own just-created skeleton,
# or the "previous workspace preserved" note would be a lie and uninstall
# would later "restore" that skeleton (or a --refresh overwrite of it) as if
# it were pre-existing state.
if [ "$WS_PREEXISTED" -eq 1 ]; then
    rm -rf "$BK"
    cp -a "$WS" "$BK"
    BK_CREATED=1
    echo "  backed up existing workspace -> $BK"
fi
if [ -f "$UNIT_FILE" ]; then
    cp "$UNIT_FILE" "$UNIT_BK"
    UNIT_BK_CREATED=1
    echo "  backed up existing unit -> $UNIT_BK"
fi

echo "--- Step 2: Deploying Artifacts ---"
# Replace-style deploy of the five shipped targets (shared deploy_workspace
# helper — also used by --refresh, so the shipped-target list can't drift)
# plus the unit file. Wiping only the shipped targets means no stale files
# survive from older versions; everything the daemon writes at runtime
# (e.g. $WS/memory/, $WS/state/) is never touched.
cp aibrain.service "$UNIT_FILE"
deploy_workspace

echo "--- Step 3: Configuring Permissions ---"
# Permissions are applied inside deploy_workspace (shared with --refresh).

echo "--- Step 3.5: Initializing Per-Skill State ---"
# Initiative 9: every skill's install.sh (init mode) creates its state files
# with defaults. Runs against the deployed workspace, non-interactive.
if [ -x "$WS/core/skill-init/init-all-skills.sh" ]; then
    WORKSPACE="$WS" bash "$WS/core/skill-init/init-all-skills.sh" --workspace "$WS" --yes || \
        echo "  WARN: per-skill init reported failures (state files can be re-seeded later)."
else
    echo "  WARN: core/skill-init/init-all-skills.sh not deployed — skipping per-skill init."
fi

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
elif command -v vulkaninfo >/dev/null 2>&1; then
    echo "  OK: vulkaninfo found — the kernel's primary VRAM path (heap-budget parsing, SETUP_COMMANDS.md §3)."
else
    echo "  WARN: none of nvidia-smi, rocm-smi, or vulkaninfo found — VRAM-based spawn deferral will"
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
if ! WORKSPACE="$HOME/.hermes/workspace" python3 "$WS/deep-brain-kernel.py" --check; then
    echo ""
    echo "Pre-flight check reported problems (see above)."
    echo "Fix them before enabling the service, then re-run this script."
    rollback
    exit 1
fi
# Deploy-count sanity: the deployed skill tree should mirror the repo exactly.
REPO_SKILL_FILES=$(find skills -type f | wc -l)
DEPLOYED_SKILL_FILES=$(find "$WS/skills" -type f | wc -l)
if [ "$REPO_SKILL_FILES" -eq "$DEPLOYED_SKILL_FILES" ]; then
    echo "  OK: $DEPLOYED_SKILL_FILES skill files deployed (matches repo)."
else
    echo "  WARN: skill file count mismatch (repo $REPO_SKILL_FILES vs deployed $DEPLOYED_SKILL_FILES)."
fi

echo ""
# ── resolve_tool_path: build the Environment=PATH= value for aibrain.service ─
# systemd --user services do NOT inherit your interactive shell's PATH
# (unit-file gotcha (a)), so the deployed unit's PATH must list every tool the
# daemon shells out to. This dedupe-preserving join of the base PATH onto the
# resolved dirs of each tool replaces the old manual 'edit the service file'
# install step. nvidia-smi/rocm-smi are portability fallbacks only (not
# expected on this box's RX 5700 XT / RDNA1 hardware) — included if present.
resolve_tool_path() {
    local base="/usr/bin:/bin:/usr/local/bin:%h/.local/bin"
    local extra=""
    for tool in hermes jq curl python3 vulkaninfo nvidia-smi rocm-smi; do
        if p=$(command -v "$tool" 2>/dev/null); then
            extra="$extra:$(dirname "$p")"
        fi
    done
    python3 - "$base" "$extra" <<'PY'
import sys
base, extra = sys.argv[1], sys.argv[2]
seen = []
for p in (base + ":" + extra).split(":"):
    if p and p not in seen:
        seen.append(p)
print(":".join(seen))
PY
}

echo "--- Step 5.5: Auto-configuring aibrain.service PATH ---"
# Resolve every tool the daemon shells out to and patch the DEPLOYED unit's
# Environment=PATH= line, so no manual service-file edit is needed. The repo
# template keeps %h/.local/bin; the resolved tool dirs are appended after it.
# The `|| base` fallback guards the bare assignment under set -e: resolve_tool_path
# invokes bare `python3`, which may legitimately be absent from PATH (Step 4
# checks the absolute /usr/bin/python3; MISSING_TOOLS below lists python3) —
# without the fallback a missing PATH entry would abort and spuriously roll
# back a fully valid deploy.
AUTO_PATH=$(resolve_tool_path) || AUTO_PATH="/usr/bin:/bin:/usr/local/bin:%h/.local/bin"
if [ -f "$UNIT_FILE" ]; then
    if grep -q '^Environment=PATH=' "$UNIT_FILE"; then
        sed -i "s|^Environment=PATH=.*|Environment=PATH=$AUTO_PATH|" "$UNIT_FILE"
        if grep -Fq "Environment=PATH=$AUTO_PATH" "$UNIT_FILE"; then
            echo "  OK: patched Environment=PATH= in $UNIT_FILE"
            echo "      -> $AUTO_PATH"
        else
            echo "  WARN: PATH patch did not verify — check $UNIT_FILE manually."
        fi
    else
        echo "  WARN: no Environment=PATH= line found in $UNIT_FILE — add one manually."
    fi
else
    echo "  WARN: $UNIT_FILE not deployed (did Step 2 fail?) — PATH auto-config skipped."
fi

# Convenience note (informational only — no pause for these):
#   cgroup delegation check: systemctl --user show -p DelegateControllers aibrain.service
#   Nice=-5 trade-off: reconsider that unit line if the machine feels laggy during spawn jobs

echo ""
echo "--- Step 5.6: Registering suite skills with Hermes Agent (Option B) ---"
# Zero-copy registration: point Hermes' skills.external_dirs at the workspace
# deploy (HERMES_COMPATIBILITY.md, Option B) so the 11 brain skills load as
# source=local without the scan-gated `hermes skills install <url>` path.
# Idempotent: no change when the path is already configured. Backs up the
# config before the first merge.
if command -v hermes >/dev/null 2>&1; then
    HERMES_CONFIG="$HOME/.hermes/config.yaml"
    EXT_DIR="~/.hermes/workspace/skills"
    if [ -f "$HERMES_CONFIG" ]; then
        # `if RESULT=$(...)` instead of a bare assignment: under set -e a
        # non-zero python exit (read-only config, write failure) would abort
        # the whole install; this routes it to the WARN case instead.
        if RESULT=$(python3 - "$HERMES_CONFIG" "$EXT_DIR" <<'PY'
import sys, pathlib, shutil, re

cfg_path, ext = sys.argv[1], sys.argv[2]
cfg = pathlib.Path(cfg_path)
lines = cfg.read_text().splitlines()

ext_found = False
skills_idx = None
ext_idx = None
for i, line in enumerate(lines):
    if not ext_found and line.strip().startswith("- ") and ext in line:
        ext_found = True
    # Block-style anchors only (Hermes writes block style, verified on this
    # host at exactly 2-space indent). Deliberately NOT relaxed to match
    # inline forms ("skills: {}", "external_dirs: [...]"): the merge inserts
    # block-style children after the matched line, which would corrupt an
    # inline map/list into invalid YAML. Missing an inline form is harmless;
    # corrupting it is not.
    if re.match(r'^skills:\s*$', line):
        skills_idx = i
    if re.match(r'^\s{2}external_dirs:\s*$', line):
        ext_idx = i

if ext_found:
    print("already")
    sys.exit(0)

bak = cfg_path + ".bak-aibrain-install"
if not pathlib.Path(bak).exists():
    shutil.copy2(cfg_path, bak)

def item_indent(line):
    m = re.match(r'^(\s*)- ', line)
    return m.group(1) if m else "  "

if ext_idx is not None:
    # Append to the existing external_dirs list, matching the indent of the
    # items Hermes itself writes (2-space: "  - path" — verified in the
    # live ~/.hermes/config.yaml). Walk past every list item after the key
    # and insert before the next non-item line.
    j = ext_idx + 1
    indent = "  "
    while j < len(lines) and re.match(r'^\s*- ', lines[j]):
        indent = item_indent(lines[j])
        j += 1
    lines.insert(j, f"{indent}- {ext}")
elif skills_idx is not None:
    lines.insert(skills_idx + 1, "  external_dirs:")
    lines.insert(skills_idx + 2, "  - " + ext)
elif any(re.match(r'^skills:', l) for l in lines):
    # A non-block "skills" form (e.g. inline "skills: {}") that the anchors
    # above didn't match. Conservative no-op: block insertion after an inline
    # map would corrupt it, and appending a duplicate skills: key would be
    # silently clobbered under last-wins YAML parsing (and for an inline
    # external_dirs: [...] it would lose the merge entirely). Hermes writes
    # block style, so this only guards a form it doesn't produce.
    print("skills-inline-skipped")
    sys.exit(0)
else:
    lines += ["", "skills:", "  external_dirs:", "  - " + ext]

cfg.write_text("\n".join(lines) + "\n")
print("merged")
PY
); then
            :
        else
            RESULT="merge-failed"
        fi
        case "$RESULT" in
            already) echo "  OK: skills.external_dirs already points at $EXT_DIR (no change)." ;;
            merged)  echo "  OK: skills.external_dirs -> $EXT_DIR written to $HERMES_CONFIG (backup: $HERMES_CONFIG.bak-aibrain-install)." ;;
            skills-inline-skipped) echo "  WARN: ~/.hermes/config.yaml has an inline 'skills:' form — not merging."
                echo "        (Hermes writes block style; add skills.external_dirs manually per HERMES_COMPATIBILITY.md Option B.)" ;;
            *)       echo "  WARN: skill registration produced an unexpected result ($RESULT) — see HERMES_COMPATIBILITY.md Option B." ;;
        esac
    else
        echo "  WARN: no $HERMES_CONFIG — Hermes has no config yet; run `hermes` once or add"
        echo "        skills.external_dirs per HERMES_COMPATIBILITY.md Option B."
    fi
else
    echo "  WARN: hermes not on PATH — skipping skill registration. The suite still runs;"
    echo "        spawn jobs use SPAWN_PROVIDER=local|agentloop instead (no harness needed)."
fi

echo ""
# The PATH gotcha is auto-handled now (Step 5.5). Only pause when a tool the
# daemon needs is genuinely missing and the user may want to fix it first.
# The pause is TTY-only: with no terminal (CI, pipes) it degrades to a note
# instead of aborting on an EOF'd `read`.
MISSING_TOOLS=""
for tool in hermes jq curl python3 vulkaninfo; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    echo "NOTE: not found on PATH:$MISSING_TOOLS"
    echo "      (warnings only — the daemon degrades gracefully, but spawn jobs / VRAM"
    echo "      checks need these; add them to Environment=PATH= in $UNIT_FILE manually"
    echo "      or export PATH before starting the service.)"
    if [ "$NONINTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
        echo "(noninteractive or no TTY) continuing with warnings"
    else
        read -r -p "Press Enter to continue (or Ctrl-C to fix $UNIT_FILE first): " _ || true
    fi
else
    echo "All daemon tools found on PATH — no manual service-file edit needed."
fi

# systemd_available() is defined near the top of the script (the --refresh
# branch and the install path below both use it).

if systemd_available; then
    SYSTEMD_OK=1
    echo "--- Step 6: Systemd Integration ---"
    systemctl --user daemon-reload
    echo "--- Step 7: Activation ---"
    systemctl --user enable --now aibrain.service
    echo "--- Step 8: Verification & Status ---"
    sleep 1
    if systemctl --user is-active --quiet aibrain.service; then
        echo "Installation Successful: Suite is active."
        systemctl --user status aibrain.service --no-pager | head -n 5 || true
        echo ""
        echo "Tail logs with: journalctl --user -u aibrain.service -f"
        systemctl --user show -p DelegateControllers aibrain.service || true
        echo "Confirm cgroup delegation: systemctl --user show -p DelegateControllers aibrain.service"
        echo "Let it run at least a full day before removing old cron entries, so every"
        echo "once-daily job gets a chance to fire and be observed succeeding — see"
        echo "BRAIN_DAEMON_SCHEDULE.md for the old-cron -> new-daemon mapping."
    else
        echo "Installation Error: Suite failed to activate."
        echo "Check: journalctl --user -u aibrain.service -e"
        exit 1
    fi
else
    echo ""
    echo "--- Step 6/7: Systemd Integration (skipped) ---"
    echo "  WARN: no systemd --user session detected (container/WSL, or not logged in)."
    echo "        The deploy is complete. Enable the service once a user session exists:"
    echo "          systemctl --user daemon-reload"
    echo "          systemctl --user enable --now aibrain.service"
    echo "--- Step 8: Deploy Complete (service not activated) ---"
    echo "  Workspace: $WS"
    echo "  Unit:      $UNIT_FILE (PATH already patched)"
fi

# Hermes skill visibility check — runs whether or not systemd was available,
# so the README quickstart's promise (install.sh verifies the registration)
# holds on containers/WSL too.
if command -v hermes >/dev/null 2>&1; then
    SKILL_COUNT=$(hermes skills list 2>/dev/null | grep -coE 'acc-error-memory|amygdala-memory|anterior-cingulate-memory|basal-ganglia-memory|cerebellum-memory|heartbeat-memory|hippocampus-memory|insula-memory|prefrontal-cortex-memory|social-memory|vta-memory' || echo "0")
    echo "Hermes skills: $SKILL_COUNT/11 brain skills visible to hermes skills list"
fi

echo ""
if [ -d "$BK" ]; then
    echo "Note: previous workspace preserved at $BK — remove it with: rm -rf $BK"
fi
