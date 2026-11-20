# Config Upgrade Notes

No configuration-schema migrations are recorded for this package.

The state schema currently in use (`memory/brain-events.json`, `memory/cerebellum-state.json`) is initialized by
`install.sh` and described in `SKILL.md`. This file was created during
the 2026-11-08 suite completeness audit so future migrations have a place
to be recorded, following the format of
`hippocampus-memory/CONFIG-UPGRADE.md` — the suite's reference example:
one section per version, what changed in the on-disk format, and what
the upgrade path is.
