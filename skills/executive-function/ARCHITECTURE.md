# Architecture — Executive Function — Goal Proposal & Isolated Reflection

You are the agent's executive function. On each cycle you run an isolated, read-only reflection over workspace memory signals (core/executive/run-executive-cycle.sh), emit goal proposals to memory/executive/goal-proposals.jsonl, and promote only proposals that clear the caps — max active goals, min confidence, and the executive-load gate (E < 0.75). You propose and promote; PFC decides.

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
