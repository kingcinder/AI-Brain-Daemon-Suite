# Changelog — Basal Ganglia Memory

All notable changes to this skill are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [0.2.2] — 2026-06-18

### Added
- `scripts/preprocess-habits.sh` — Scans session transcripts for habit
  signals using watermark-aware incremental processing (same watermark
  strategy as hippocampus-memory)
- `scripts/encode-pipeline.sh` — Full 5-step encoding orchestration:
  preprocess → heuristic scoring → pending-habits.json → watermark advance →
  sync. Detects reinforcement candidates (word-overlap ≥ 35%) without LLM call.
- `scripts/decay-habits.sh` — Time-based strength decay: habits and
  procedures at 3%/day from `lastFired`/`lastUsed`; suppressions at 0.5%/day
  from `lastReinforced` (corrections stick). Guards against double-running.
- `scripts/sync-state.sh` — Regenerates `BASAL_GANGLIA_STATE.md` (chunked
  context injection file) and triggers `generate-dashboard.sh`.
- `scripts/generate-dashboard.sh` — Full 4-tab brain dashboard extending the
  hippocampus/amygdala/vta shared HTML with a `🎯 Habits` tab. Shows habit
  strength bars, procedure step chains, and suppression tags.
- `prompts/encode-habits.md` — LLM sub-agent classification prompt: maps
  signals to new habit / reinforce / new procedure / new suppression / skip.
- `ARCHITECTURE.md` — Technical design: system diagram, schema, strength
  math, pipeline internals, dashboard integration.
- `CHANGELOG.md` — This file.

### Fixed
- `reinforce-habit.sh`: `SKILL_DIR` was computed as `dirname/..` (correct
  only for scripts living inside `scripts/`) but this script lives at the
  skill root. Fixed to `dirname/.`, and corrected `$SKILL_DIR/scripts/log-event.sh`
  calls to `$SKILL_DIR/log-event.sh`.
- `install.sh`: `chmod` only covered `scripts/*.sh` — now also chmods
  root-level CLI scripts. Fixed "next steps" hint pointing at
  `scripts/load-habits.sh` (doesn't exist there).
- `log-event.sh`: doc comments said `./scripts/log-event.sh`; corrected to
  `./log-event.sh`.

### Changed
- `skill-card.md`: Updated description to reflect live v0.2.2 feature set;
  removed placeholder risk language.
- `_meta.json`: Version bumped to `0.2.2`.

---

## [0.2.1] — 2026-06-15 (UNFINISHED)

### Added
- `install.sh` — Full installer with `--with-cron`, `--signals N`,
  `--whole` flags; initializes `habit-state.json`.
- `get-habits.sh` — Table view (habits / procedures / suppressions) with
  `--type`, `--status`, `--category`, `--json` filters.
- `load-habits.sh` — Session context injection in prose / brief / JSON modes.
- `reinforce-habit.sh` — Swiss-army tool: `--list`, `--id` (reinforce /
  weaken), `--new` (habit / procedure), `--suppress`.
- `log-event.sh` — Appends typed events to `brain-events.jsonl`.
- `update-watermark.sh` — Sets `lastProcessedSignal` from signals file or a
  specific ID.
- `README.md` — Human-readable guide with installation, workflow, and
  troubleshooting.
- `SKILL.md` — Full OpenClaw reference with schema, encoding pipeline
  explanation, manual operation examples.
- `skill-card.md` — OpenClaw marketplace card (preliminary).

### Notes
- `scripts/` pipeline and `prompts/` directory were planned but not created
  before the session ran out of tokens. Completed in 0.2.2.

---

## [0.1.1] — 2026-05-14 (Placeholder)

### Added
- `SKILL.md` — Placeholder / concept document describing planned features.
- `_meta.json` — Initial version metadata.
- `skill-card.md` — Minimal marketplace card for placeholder release.
- `TUTORIAL_FOR_BASAL_GANGLIA_MEMORY_SKILL_0.1.md` — Concept tutorial.

### Notes
- Documentation-only release. No functional scripts.
