# Changelog

All notable changes to the self-mod-runner skill (bash-suite record).

## [2026-11-20] Juno-direct scrub

- Proposal generation is Juno-authored: run-pipeline.sh --generate-juno drives generate-proposals-juno.sh (core/self-mod), which asks Juno through the helm queue. The hermes/openrouter/local-server providers are removed.
- proposal-cycle-tick.sh and rollback-learning.sh updated to the Juno generator.

## [0.1.0] - 2026-11-08

### Added
- Ported into the bash AI Brain Daemon Suite from the kernel lineage
  (GitHub kingcinder/AI-Brain-Daemon-Suite @ 11b3db1), Dyther decision #7.
- Suite-standard files created (skill-card.md, README.md,
  ARCHITECTURE.md, CONFIG-UPGRADE.md, agentdir/, agents/, prompts/,
  _meta.json) per the suite's organ pattern.

### Changed
- WORKSPACE defaults repointed from ~/.hermes/workspace (kernel era) to
  ~/.openclaw/workspace (bash-suite convention).
