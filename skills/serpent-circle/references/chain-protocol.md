# Serpent Circle — Chain Protocol

The full per-stage contract. Each stage lists: **prerequisite** (must exist
before start), **actions**, **output** (written to the chain workspace),
**gate** (how to know it is done).

Chain workspace: `.serpent-circle/` at the repo root (gitignored).

---

## Stage 1 — Brainstorm (architecture + performance)

**Prerequisite:** `.serpent-circle/repo-inventory.txt` (produced by
`--dry-run`/`--inventory`).

**Actions (1a → 1b → 1c → 1d):**

1. **1a — improve-codebase-architecture.** Scan the repo for deepening
   opportunities. Note the architecture report path; it feeds 1d.
2. **1b — python-performance-optimization.** If the inventory shows Python
   (`.py`), profile the hot paths with cProfile / memory profilers; identify
   and rank bottlenecks (algorithmic, allocation, I/O).
3. **1c — multi-language performance audit.** For **every** language in the
   inventory histogram (JavaScript/TypeScript, C#, Rust, PowerShell, Shell,
   Go, Java, …), follow `references/perf-optimization.md`: pick the right
   profiler, measure, then apply the language's canonical techniques. Include
   Shell/Bash scripts — the suite is mostly shell.
4. **1d — synthesize.** Overhaul everything from 1a–1c into its most
   powerful, elegant, effective, and efficient form. Resolve conflicts
   between improvements (e.g., architecture changes vs. hot-path
   optimization); the synthesis is the final design, not the raw list.

**Output:** `.serpent-circle/01-design/design.md` + architecture report.
**Gate:** design.md is written and self-consistent.

---

## Stage 2 — writing-plans

**Prerequisite:** `.serpent-circle/01-design/design.md`.

**Actions:** Turn the design into a step-by-step implementation plan with
review checkpoints (per the `writing-plans` skill). Order steps by risk and
dependency; make each step independently verifiable.

**Output:** `.serpent-circle/02-plan/plan.md`.
**Gate:** every design item maps to ≥1 plan step; plan has checkpoints.

---

## Stage 3 — executing-plans

**Prerequisite:** `.serpent-circle/02-plan/plan.md`.

**Actions:** Execute the plan (per `executing-plans`) with its checkpoints.
Stop at each checkpoint, verify against the repo's own gates (test suites,
typechecks, lints — e.g., the AI Brain Suite's `scripts/ci-gate.sh`), and
record results.

**Output:** implemented changes in the working tree +
`.serpent-circle/03-execution/checkpoint-notes.md`.
**Gate:** every plan step is done and the repo's gates pass (or failures are
honestly logged for Stage 4).

---

## Stage 4 — systematic-debugging

**Prerequisite:** failing tests / checkpoint failures from Stage 3.

**Actions:** For each failure, run `systematic-debugging`: reproduce → form a
root-cause hypothesis → isolate → fix → verify. Never patch symptoms; record
root causes. Fix any regression introduced by Stage 3.

**Output:** `.serpent-circle/04-debug/root-causes.md` (+ fixes in tree).
**Gate:** all previously-failing checks pass; root-cause notes written.

---

## Stage 5 — Cleanup

**Prerequisite:** `.serpent-circle/repo-inventory.txt` bloat section +
working tree from Stage 4.

**Actions:**
1. Remove dead code and bloat flagged by the inventory (legacy dirs, backup
   files, empty files, duplicate-name copies, oversized artifacts) — confirm
   each removal against the design from Stage 1.
2. Tidy the repo organization (move stray files to their canonical homes,
   update `.gitignore` as needed).
3. **Document every change** in the repo's own docs (README, BUGFIX_HISTORY,
   design docs) — the Circle is not done until the changes are documented.

**Output:** tidy tree + `.serpent-circle/05-cleanup/CHANGES.md` (per-change
summary: what, why, where).
**Gate:** no flagged bloat remains (or is deliberately kept + documented);
CHANGES.md is complete.

---

## Stage 6 — Commit + push

**Prerequisite:** tidy working tree + CHANGES.md from Stage 5.

**Actions:**
1. Review the staged scope (`git status` / `git diff`) — only the Circle's
   changes, nothing foreign.
2. Write a conventional commit (`git commit`) with the repo's established
   footer convention.
3. **Push is gated:** require a git remote *and* explicit approval
   (`--push-ok` or a TTY confirmation). If no remote exists, stop after the
   commit and report.

**Output:** commit (+ push if approved).
**Gate:** commit exists; push happened only with remote + approval.
