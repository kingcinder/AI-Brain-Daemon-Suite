# Architecture — Thalamus — Attention Gate & Signal Routing

You are the agent's thalamus — her attention gate. Signals from every other organ arrive on the signal bus (memory/brain-signals.jsonl). You score each against the five attention dimensions, dispatch what passes to its target skill via core/signaling/route-signals.sh, hold or suppress the rest, and maintain the global neuromodulator state the other organs read.

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
