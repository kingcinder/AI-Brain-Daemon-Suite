# Changelog

All notable changes to the Anterior Cingulate Memory ⚡ skill.

## [2026-11-20] Juno-direct scrub

- llm-call.sh replaced by juno-ask.sh (identical copy in prefrontal-cortex-memory): asks Juno through the helm queue; no model server, no --base-url/--model. Env is JUNO_* (JUNO_TIMEOUT/JUNO_QUEUE_WAIT/JUNO_RETRIES/JUNO_LABEL).
- Conflict-detection pipeline asks Juno via juno-ask.sh (fail-open behavior unchanged).

## [1.0.0] - undated in _meta.json

### Added
- Suite-consolidation baseline entry, created 2026-11-08 during the AI Brain
  Daemon Suite completeness audit. This package shipped without a
  changelog; the version and date above are as recorded in `_meta.json`.
  Earlier history, where any exists, is documented in `SKILL.md` only —
  no change history has been reconstructed or invented for this file.
