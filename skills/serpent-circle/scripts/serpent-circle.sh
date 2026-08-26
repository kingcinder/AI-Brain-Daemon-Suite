#!/bin/bash
# serpent-circle.sh — Serpent Circle meta-skillchain orchestrator (deterministic spine).
#
# Chains six existing skills into one repo-renovation pipeline; each stage's
# output feeds the next via the .serpent-circle/ workspace:
#   Stage 1  Brainstorm           improve-codebase-architecture → python-performance-
#                                 optimization → multi-language perf audit → synthesize
#   Stage 2  writing-plans        plan from the design doc
#   Stage 3  executing-plans      implement + validate the plan
#   Stage 4  systematic-debugging root-cause + fix failures
#   Stage 5  Cleanup              dead code, bloat, tidying, documentation
#   Stage 6  Commit + push        conventional commit; push gated on remote + approval
#
# This script is the deterministic spine: repo inventory, .serpent-circle/
# scaffolding, the per-stage dry-run plan, and the safety gates. The
# model-judgment stages are driven by the agent using the skill; this script
# supplies the scan data and enforces the gates around them.
#
# SAFETY:
#   --dry-run  writes ONLY inside the gitignored .serpent-circle/ workspace;
#              never touches tracked files, never commits, never pushes.
#   Stage 6    refuses to run without a git remote AND explicit approval
#              (--push-ok or a TTY confirmation).
set -euo pipefail

REPO=""
DRY_RUN=0
INVENTORY_ONLY=0
SELF_TEST=0
STAGE=""
PUSH_OK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<'EOF'
Serpent Circle — meta-skillchain orchestrator

Usage:
  serpent-circle.sh --help
  serpent-circle.sh --self-test
  serpent-circle.sh --inventory [--repo PATH]
  serpent-circle.sh --dry-run   [--repo PATH]
  serpent-circle.sh --stage N   [--repo PATH]
  serpent-circle.sh --push-ok   [--repo PATH]

Options:
  --help        Show this help and exit.
  --self-test   Validate the skill's own files (SKILL.md, references,
                manifest schema, script syntax) and exit.
  --inventory   Scan the target repo and print the inventory only.
  --dry-run     Produce the full 6-stage plan in the gitignored
                .serpent-circle/ workspace with NO execution, NO commit,
                NO push. Never touches tracked files. Safe to run anywhere.
  --stage N     Run stage N's deterministic parts (1-6). Stages 1-5 are
                model-judgment stages (the script checks prerequisites and
                scaffolds); Stage 6 enforces the push gate.
  --push-ok     Explicit approval override for Stage 6's push gate (real
                mode only; --dry-run never pushes regardless).
  --repo PATH   Target repo (default: nearest .git above cwd).
EOF
}

die() { echo "serpent-circle: $*" >&2; exit 1; }

find_repo() {
    if [ -n "$REPO" ]; then
        [ -d "$REPO" ] || die "repo dir not found: $REPO"
        printf '%s\n' "$REPO"
        return 0
    fi
    local d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -d "$d/.git" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    die "no git repo found from $PWD (use --repo PATH)"
}

git_state() {
    local repo="$1"
    local branch remote dirty commits
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || echo 'none')"
    dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    commits="$(git -C "$repo" log --oneline -1 2>/dev/null || echo 'no commits')"
    printf 'branch:            %s\nremote:            %s\nuncommitted files: %s\nHEAD:              %s\n' \
        "$branch" "$remote" "$dirty" "$commits"
}

# Extension histogram over the repo (excluding .git and the chain workspace).
language_inventory() {
    local repo="$1"
    find "$repo" -type f \
        -not -path '*/.git/*' \
        -not -path '*/.serpent-circle/*' \
        -not -path '*/__pycache__/*' \
        -print0 2>/dev/null |
    python3 -c '
import collections, os, sys
counts = collections.Counter()
langs = {
    ".py": "python", ".js": "javascript", ".jsx": "javascript",
    ".ts": "typescript", ".tsx": "typescript", ".cs": "csharp",
    ".rs": "rust", ".ps1": "powershell", ".psm1": "powershell",
    ".sh": "shell", ".bash": "shell", ".go": "golang", ".java": "java",
    ".rb": "ruby", ".php": "php", ".swift": "swift", ".kt": "kotlin",
    ".c": "c", ".h": "c", ".cpp": "cpp", ".cc": "cpp", ".html": "html",
    ".css": "css", ".sql": "sql", ".json": "json", ".yaml": "yaml",
    ".yml": "yaml", ".md": "markdown", ".toml": "toml",
}
for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw:
        continue
    ext = os.path.splitext(raw.decode("utf-8", "replace"))[1].lower()
    counts[langs.get(ext, "other")] += 1
for lang, n in counts.most_common():
    print(f"{n:6d}  {lang}")
'
}

bloat_candidates() {
    local repo="$1"
    local out
    out="$({
        echo "--- dead/legacy dirs ---"
        find "$repo" -maxdepth 2 -type d \( -name 'legacy-IGNORE' -o -name 'legacy' \) \
            -not -path '*/.git/*' 2>/dev/null
        echo "--- backup / junk files ---"
        find "$repo" -type f \( -name '*.bak*' -o -name '*~' -o -name '*.orig' \
            -o -name '*.rej' -o -name '*.pyc' \) \
            -not -path '*/.git/*' -not -path '*/.serpent-circle/*' 2>/dev/null
        echo "--- empty files ---"
        find "$repo" -type f -empty -not -path '*/.git/*' \
            -not -path '*/.serpent-circle/*' 2>/dev/null
        echo "--- duplicate-name copies ---"
        find "$repo" -type f \( -iname '*copy*' -o -iname '*.copy' \) \
            -not -path '*/.git/*' 2>/dev/null
        echo "--- oversized files (>1MB) ---"
        find "$repo" -type f -size +1M -not -path '*/.git/*' \
            -not -path '*/.serpent-circle/*' 2>/dev/null
    } 2>/dev/null | python3 -c '
import sys
repo = sys.argv[1]
for line in sys.stdin.read().splitlines():
    if line.startswith(repo + "/"):
        line = line[len(repo) + 1:]
    print(line)
' "$repo" 2>/dev/null | head -60)" || true
    [ -n "$out" ] && printf '%s\n' "$out" || echo "(none)"
}

# state.json ledger — gates and stage tracking read this.
write_state() {
    local repo="$1" ws="$2" mode="$3"
    python3 - "$repo" "$ws" "$mode" <<'PY'
import json, sys, datetime
repo, ws, mode = sys.argv[1], sys.argv[2], sys.argv[3]
state = {
    "skill": "serpent-circle",
    "repo": repo,
    "mode": mode,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "stages": [
        "1-brainstorm", "2-writing-plans", "3-executing-plans",
        "4-systematic-debugging", "5-cleanup", "6-commit-push",
    ],
    "stages_completed": [],
    "dry_run": mode == "dry-run",
}
with open(ws + "/state.json", "w") as f:
    f.write(json.dumps(state, indent=2) + "\n")
PY
}

write_plan() {
    local repo="$1" ws="$2"
    python3 - "$repo" "$ws" <<'PY'
import datetime, sys
repo, ws = sys.argv[1], sys.argv[2]
lines = open(ws + "/repo-inventory.txt").read().splitlines()

def section(title):
    for i, l in enumerate(lines):
        if l.startswith(title):
            return i
    return None

lang_i = section("## Languages")
bloat_i = section("## Bloat")
langs = "\n".join(lines[lang_i + 1:bloat_i]).strip() if (lang_i is not None and bloat_i is not None) else "(scan unavailable)"
bloat = "\n".join(lines[bloat_i + 1:]).strip() if bloat_i is not None else "(scan unavailable)"

plan = f"""# Serpent Circle — chain plan (DRY-RUN)

Generated: {datetime.datetime.now(datetime.timezone.utc).isoformat()}
Target repo: `{repo}`
Mode: DRY-RUN — this is the full 6-stage itinerary. Nothing was executed or committed.

## Stage 1 — Brainstorm (architecture + performance)
Chains: improve-codebase-architecture → python-performance-optimization →
multi-language perf audit → synthesize.

1. Run improve-codebase-architecture over the repo; capture the deepening-opportunities report.
2. Profile Python hot paths (cProfile / memory profilers) per python-performance-optimization.
3. Audit every non-Python language below per references/perf-optimization.md.
4. Synthesize into the most powerful/elegant/effective form.
Output: `01-design/design.md` — feeds Stage 2.

### Languages detected
{langs}

## Stage 2 — writing-plans
Consumes: `01-design/design.md`. Produces a step-by-step plan with review
checkpoints: `02-plan/plan.md`. Feeds Stage 3.

## Stage 3 — executing-plans
Consumes: `02-plan/plan.md`. Executes with checkpoints; validates against the
repo's own gates (test suites / typechecks / lints). Feeds Stage 4.

## Stage 4 — systematic-debugging
Consumes: failing tests / regressions from Stage 3. Root-cause each failure
(reproduce → isolate → fix → verify). Feeds Stage 5.

## Stage 5 — Cleanup
Dead code, bloat, and tidying per the candidate scan below; document every
change in the repo docs (README / BUGFIX_HISTORY). Output: `05-cleanup/CHANGES.md`.
Feeds Stage 6.

### Bloat / dead-code candidates
{bloat}

## Stage 6 — Commit + push
Consumes: the tidy working tree. Conventional commit; push is gated on a git
remote AND explicit approval (--push-ok or TTY confirm). Dry-run never pushes.
"""
with open(ws + "/chain-plan.md", "w") as f:
    f.write(plan)
print("Plan written: " + ws + "/chain-plan.md")
PY
}

dry_run() {
    local repo="$1"
    local ws="$repo/.serpent-circle"
    mkdir -p "$ws"/01-design "$ws"/02-plan "$ws"/03-execution \
        "$ws"/04-debug "$ws"/05-cleanup "$ws"/06-commit

    {
        echo "# Serpent Circle — repo inventory"
        date -u +'generated_at: %Y-%m-%dT%H:%M:%SZ'
        echo
        echo "## Git state"
        git_state "$repo"
        echo
        echo "## Languages"
        language_inventory "$repo"
        echo
        echo "## Bloat / dead-code candidates"
        bloat_candidates "$repo"
    } > "$ws/repo-inventory.txt"

    write_state "$repo" "$ws" "dry-run"
    write_plan "$repo" "$ws"

    echo "--- Repo state ---"
    git_state "$repo"
    echo
    echo "--- Languages ---"
    language_inventory "$repo"
    echo
    echo "--- Bloat / dead-code candidates ---"
    bloat_candidates "$repo"
    echo
    echo "Dry-run complete → $ws/chain-plan.md (plan only; nothing executed, nothing committed)."
}

inventory_only() {
    local repo="$1"
    echo "--- Repo state ---"
    git_state "$repo"
    echo
    echo "--- Languages ---"
    language_inventory "$repo"
    echo
    echo "--- Bloat / dead-code candidates ---"
    bloat_candidates "$repo"
}

self_test() {
    local fail=0
    local f
    for f in SKILL.md references/chain-protocol.md references/perf-optimization.md \
        scripts/serpent-circle.sh capability-manifest.json; do
        if [ -f "$SKILL_DIR/$f" ]; then
            echo "OK   $f"
        else
            echo "FAIL $f missing"
            fail=1
        fi
    done
    if bash -n "$0" 2>/dev/null; then
        echo "OK   orchestrator syntax"
    else
        echo "FAIL orchestrator syntax"
        fail=1
    fi
    local root
    root="$(cd "$SKILL_DIR/../.." && pwd)"
    if [ -x "$root/core/schema/validate-manifest.sh" ]; then
        if bash "$root/core/schema/validate-manifest.sh" "$SKILL_DIR/capability-manifest.json" >/dev/null 2>&1; then
            echo "OK   manifest schema"
        else
            echo "FAIL manifest schema"
            fail=1
        fi
    else
        echo "SKIP manifest schema (validate-manifest.sh absent)"
    fi
    if [ "$fail" -eq 0 ]; then
        echo "Serpent Circle self-test: OK"
    else
        die "self-test failed"
    fi
}

stage_run() {
    local repo="$1" n="$2"
    case "$n" in
        1 | 2 | 3 | 4 | 5)
            mkdir -p "$repo/.serpent-circle"
            echo "Stage $n: prerequisites OK (workspace ready). Drive this stage per references/chain-protocol.md (model-judgment stage)."
            ;;
        6)
            local remote
            remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
            if [ -z "$remote" ]; then
                die "stage 6: no git remote — cannot push (gated). Commit only, then report."
            fi
            if [ "$PUSH_OK" -ne 1 ]; then
                if [ -t 0 ]; then
                    read -r -p "Push to $remote? (yes/no): " ans || ans=""
                    [ "$ans" = "yes" ] || die "stage 6: push aborted (no confirmation)"
                else
                    die "stage 6: push requires --push-ok (no TTY, no implicit push)"
                fi
            fi
            echo "Stage 6 gate passed: remote=$remote, push approved."
            ;;
        *)
            die "unknown stage: $n (expected 1-6)"
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help | -h) usage; exit 0 ;;
        --self-test) SELF_TEST=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --inventory) INVENTORY_ONLY=1; shift ;;
        --stage) STAGE="${2:-}"; [ -n "$STAGE" ] || die "--stage requires N (1-6)"; shift 2 ;;
        --repo) REPO="${2:-}"; [ -n "$REPO" ] || die "--repo requires PATH"; shift 2 ;;
        --push-ok) PUSH_OK=1; shift ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    exit 0
fi

REPO="$(find_repo)"

if [ "$INVENTORY_ONLY" -eq 1 ]; then
    inventory_only "$REPO"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    dry_run "$REPO"
    exit 0
fi

if [ -n "$STAGE" ]; then
    stage_run "$REPO" "$STAGE"
    exit 0
fi

usage >&2
die "no mode selected (--self-test | --inventory | --dry-run | --stage N)"
