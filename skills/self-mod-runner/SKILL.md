# self-mod-runner

Daemon-facing entrypoints for the Phase 3 self-modification **monitor** loop.

The pipeline itself lives under `core/self-mod/` and is **Immutable Core** for proposal targets.
This skill only *invokes* monitor (and may later invoke scheduled pipeline runs).

## Scripts

- `scripts/monitor-tick.sh` — calls `core/self-mod/monitor.sh`
