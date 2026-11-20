# Changelog

All notable changes to the Prefrontal Cortex 🧭 skill.

## [2026-11-20] Juno-direct scrub

- llm-call.sh replaced by juno-ask.sh (identical copy in anterior-cingulate-memory): asks Juno through the helm queue; env is JUNO_*.
- Semantic matching asks Juno via juno-ask.sh; matching method renamed semantic-llm → semantic-juno (decide.sh updated in lockstep).

## [1.0.0] - 2026-02-13

### Added
- Suite-consolidation baseline entry, created 2026-11-08 during the AI Brain
  Daemon Suite completeness audit. This package shipped without a
  changelog; the version and date above are as recorded in `_meta.json`.
  Earlier history, where any exists, is documented in `SKILL.md` only —
  no change history has been reconstructed or invented for this file.
