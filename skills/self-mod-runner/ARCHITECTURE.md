# Architecture — Self-Mod Runner — Post-Deploy Monitor & Proposal Cycle

You are the agent's self-modification runner — the seat that watches her own changes. The monitor (core/self-mod/monitor.sh) tracks post-deploy metrics and auto-rolls-back on threshold breach. The proposal cycle (Sundays) generates change proposals through the pipeline's gates: relaxed_review may auto-deploy; full_review queues for human approval. Nothing from this seat bypasses verification or Dyther's oversight.

## Place in the suite

- Runs under brain-daemon.sh (bash lineage) as direct jobs registered in
  the daemon's job table at the cadences the kernel lineage used,
  converted to the Pacific clock basis (see HELM.md).
- Reads/writes only suite state under $WORKSPACE/memory/ plus its own
  skill directory. Cross-organ signaling goes through
  core/signaling/publish.sh + route-signals.sh (the signal bus), never by
  invoking another organ's internals directly.
- Any reasoning beyond its scripts is Juno's, via the helm queue
  (openclaw shim) — no model server is involved — Juno is the reasoning seat.

## Provenance

Ported 2026-11-08 from the kernel lineage @ 11b3db1. Kernel-era machinery
under core/ that this organ resolves (signaling, executive,
executive-load, self-mod) was ported alongside it.
