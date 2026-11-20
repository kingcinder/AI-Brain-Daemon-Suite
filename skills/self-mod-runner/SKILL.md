# self-mod-runner

Daemon-facing entrypoints for the Phase 3 self-modification **monitor** loop.

The pipeline itself lives under `core/self-mod/` and is **Immutable Core** for proposal targets.
This skill only *invokes* monitor (and may later invoke scheduled pipeline runs).

## Scripts

- `scripts/monitor-tick.sh` — calls `core/self-mod/monitor.sh`
- `scripts/proposal-cycle-tick.sh` — weekly `self_mod_proposal_cycle`: runs
  `core/self-mod/run-pipeline.sh` with `--autonomy-gate --defer-gate`. **M9
  (2026-11-13): Juno is the approval gate.** The cycle never defers and no
  proposal queues for human approval — an accepted proposal deploys on
  Juno's approval in any autonomy/review mode, recorded as
  `autonomy.gate.deploy_allowed` (approver:"juno"). `--defer-gate` is
  retained for flag back-compat and is ignored. The tick's deferral-alert
  block is legacy: it can only clear a stale `last-deferral.json` marker
  left by a pre-M9 run; no new deferrals (or `cycle_deferred` signals) are
  ever produced.
- `scripts/generate-dashboard.sh` — writes the 🛠 Self-Mod dashboard fragment
  (streak, live metrics, pipeline activity) plus an **Autonomy Gate ·
  Provenance** timeline: the last 12 `autonomy.*` audit events from
  `memory/provenance/events.jsonl` (`autonomy.mode.decided` from the kernel,
  `autonomy.gate.deferred` / `deploy_blocked` / `deploy_allowed` from the
  pipeline). Baked at build time, live-refreshed from `/__daemon` when served
  — the steward sees the gate's full history in the GUI, not just on disk.
