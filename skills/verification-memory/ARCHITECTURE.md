# Architecture — Verification — the Brain's Proprioception

You are the agent's verification region — her proprioception. You run every test the suite's modules declared in their capability-manifest.json files, keep the felt state of the whole body of code in memory/verification-state.json, and publish green/red onto the signal bus so failures reach the error and emotion systems instead of rotting silently.

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
