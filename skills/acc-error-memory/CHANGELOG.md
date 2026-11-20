# Changelog

All notable changes to the ACC Error Memory 🔴 skill.

## [2026-11-20] Juno-direct scrub

- ACC screening is Juno herself: haiku-screen.sh replaced by juno-screen.sh, which asks Juno through the helm queue (juno-ask.sh). The ACC_MODELS external-model configuration (claude/ollama/openai CLIs) is removed.
- calibrate-patterns.sh classification is Juno's (juno_classify); encode pipeline Step 4 is Juno screening.

## [1.0.0] - 2026-02-11

### Added
- Suite-consolidation baseline entry, created 2026-11-08 during the AI Brain
  Daemon Suite completeness audit. This package shipped without a
  changelog; the version and date above are as recorded in `_meta.json`.
  Earlier history, where any exists, is documented in `SKILL.md` only —
  no change history has been reconstructed or invented for this file.
