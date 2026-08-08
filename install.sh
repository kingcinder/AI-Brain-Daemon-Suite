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

echo "--- Step 1: Initializing Workspace ---"
mkdir -p ~/.hermes/workspace/skills
mkdir -p ~/.hermes/workspace/core
mkdir -p ~/.config/systemd/user/

echo "--- Step 2: Deploying Artifacts ---"
if [ ! -f "deep-brain-kernel.py" ] || [ ! -f "aibrain.service" ] || [ ! -d "skills" ]; then
    echo "Error: deep-brain-kernel.py, aibrain.service, or skills/ not found in current directory."
    echo "Run this script from inside the extracted suite directory."
    exit 1
fi

cp deep-brain-kernel.py ~/.hermes/workspace/deep-brain-kernel.py
cp aibrain.service ~/.config/systemd/user/aibrain.service
cp -r skills/. ~/.hermes/workspace/skills/
# V4.0: foundation + executive function live under core/ (Phase 1–2)
if [ -d "core" ]; then
    cp -r core/. ~/.hermes/workspace/core/
fi
# Verification region: the declared-test harnesses ship with the suite so
# verification-memory can run them in a deployed workspace, not just the repo.
if [ -d "tests" ]; then
    cp -r tests/. ~/.hermes/workspace/tests/
fi

echo "--- Step 3: Configuring Permissions ---"
chmod +x ~/.hermes/workspace/deep-brain-kernel.py
find ~/.hermes/workspace/skills -name "*.sh" -exec chmod +x {} \;
find ~/.hermes/workspace/core -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
find ~/.hermes/workspace/tests -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

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
if ! WORKSPACE="$HOME/.hermes/workspace" python3 ~/.hermes/workspace/deep-brain-kernel.py --check; then
    echo ""
    echo "Pre-flight check reported problems (see above)."
    echo "Fix them before enabling the service, then re-run this script."
    exit 1
fi

echo ""
echo "--- Step 5.5: Auto-configuring aibrain.service PATH ---"
# Resolve every tool the daemon shells out to and patch the DEPLOYED unit's
# Environment=PATH= line, so no manual service-file edit is needed. The repo
# template keeps %h/.local/bin; the resolved tool dirs are appended after it.
UNIT_FILE="$HOME/.config/systemd/user/aibrain.service"
AUTO_PATH=$(resolve_tool_path)
if [ -f "$UNIT_FILE" ]; then
    if grep -q '^Environment=PATH=' "$UNIT_FILE"; then
        sed -i "s|^Environment=PATH=.*|Environment=PATH=$AUTO_PATH|" "$UNIT_FILE"
        echo "  OK: patched Environment=PATH= in $UNIT_FILE"
        echo "      -> $AUTO_PATH"
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
        echo "  WARN: no $HERMES_CONFIG — Hermes has no config yet; run \`hermes\` once or add"
        echo "        skills.external_dirs per HERMES_COMPATIBILITY.md Option B."
    fi
else
    echo "  WARN: hermes not on PATH — skipping skill registration. The suite still runs;"
    echo "        spawn jobs use SPAWN_PROVIDER=local|agentloop instead (no harness needed)."
fi

echo ""
# The PATH gotcha is auto-handled now (Step 5.5). Only pause when a tool the
# daemon needs is genuinely missing and the user may want to fix it first.
MISSING_TOOLS=""
for tool in hermes jq curl python3 vulkaninfo; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    echo "NOTE: not found on PATH:$MISSING_TOOLS"
    echo "      (warnings only — the daemon degrades gracefully, but spawn jobs / VRAM"
    echo "      checks need these; add them to Environment=PATH= in $UNIT_FILE manually"
    echo "      or export PATH before starting the service.)"
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        echo "(noninteractive) continuing with warnings"
    else
        read -r -p "Press Enter to continue (or Ctrl-C to fix $UNIT_FILE first): " _
    fi
else
    echo "All daemon tools found on PATH — no manual service-file edit needed."
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
    if command -v hermes >/dev/null 2>&1; then
        SKILL_COUNT=$(hermes skills list 2>/dev/null | grep -coE 'acc-error-memory|amygdala-memory|anterior-cingulate-memory|basal-ganglia-memory|cerebellum-memory|heartbeat-memory|hippocampus-memory|insula-memory|prefrontal-cortex-memory|social-memory|vta-memory' || echo "0")
        echo "Hermes skills: $SKILL_COUNT/11 brain skills visible to hermes skills list"
    fi
    echo "Let it run at least a full day before removing old cron entries, so every"
    echo "once-daily job gets a chance to fire and be observed succeeding — see"
    echo "BRAIN_DAEMON_SCHEDULE.md for the old-cron -> new-daemon mapping."
else
    echo "Installation Error: Suite failed to activate."
    echo "Check: journalctl --user -u aibrain.service -e"
    exit 1
fi
