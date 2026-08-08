# self-mod-runner

Daemon-facing entrypoints for the Phase 3 self-modification **monitor** loop.

The pipeline itself lives under `core/self-mod/` and is **Immutable Core** for proposal targets.
This skill only *invokes* monitor (and may later invoke scheduled pipeline runs).

## Scripts

- `scripts/monitor-tick.sh` — calls `core/self-mod/monitor.sh`
- `scripts/proposal-cycle-tick.sh` — weekly `self_mod_proposal_cycle`: runs
  `core/self-mod/run-pipeline.sh` with `--autonomy-gate --defer-gate`, so a
  steward_mode + full_review contract defers the cycle (no churn) and logs an
  `autonomy.gate.deferred` provenance event. **Deferral alert:** when the
  pipeline reports `deferred:true`, the tick appends a
  `{type:"self-mod", event:"cycle_deferred"}` signal to the shared
  `brain-events.jsonl` and writes `memory/self-mod/last-deferral.json` — the
  marker `deep-brain-kernel.py --status`, the dashboard `/__daemon`, and the
  status-bar ⏸ pill read, so a steward who expected the weekly cycle to run
  notices it waited for the human. A non-deferred run clears the marker.
- `scripts/generate-dashboard.sh` — writes the 🛠 Self-Mod dashboard fragment
  (streak, live metrics, pipeline activity) plus an **Autonomy Gate ·
  Provenance** timeline: the last 12 `autonomy.*` audit events from
  `memory/provenance/events.jsonl` (`autonomy.mode.decided` from the kernel,
  `autonomy.gate.deferred` / `deploy_blocked` / `deploy_allowed` from the
  pipeline). Baked at build time, live-refreshed from `/__daemon` when served
  — the steward sees the gate's full history in the GUI, not just on disk.
