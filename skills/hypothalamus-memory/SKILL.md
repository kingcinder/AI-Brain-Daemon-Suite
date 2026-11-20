---
name: hypothalamus-memory
description: "Homeostatic regulation for the brain harness — the hypothalamus organ. Owns the set-points for the collective's internal milieu variables (queue pressure, backlog load, dead letters, disk headroom, interoceptive saturation) and issues corrective drive envelopes when a variable leaves its bounds. Created 2026-11-20 under Phase G (Amendment 4) of the Gated-Ingress Refactor: the coverage audit found homeostasis ABSENT — the insula senses milieu state and the patrol detects capacity breaches, but no organ owned regulation. The 2026-11-18 rogue-healer outage was a homeostatic failure: a corrective drive with no set-point owner."
metadata:
  openclaw:
    emoji: "🌡️"
    version: "1.0.0"
    author: "Juno (Gated-Ingress Refactor, Phase G)"
    requires:
      os: ["linux"]
      bins: ["jq", "python3"]
---

# Hypothalamus — homeostatic regulation

Biological counterpart: the **hypothalamus** — the brain's homeostat.
It senses internal-milieu variables (temperature, osmolality, glucose,
fatigue) against set-points and issues corrective drives — behavioral
(thirst, hunger, sleep-seeking) and hormonal — until the variable
returns to bounds. It does not sense for its own sake (that is the
insula's interoception) and it does not judge errors (that is the
ACC's verdict): it REGULATES.

## Duty in this harness

Each regulation pass reads the milieu variables, compares them to
the set-points stored in its own state, and for every variable out
of bounds issues a **corrective drive**: a gated envelope
(type `homeostasis.drive`) routed to the responsible organ's flow
or, when severe, to the helm decision queue — plus a ledger entry in
`memory/homeostasis-ledger.jsonl`. Drives repeat on each pass while
the variable stays out of bounds (a drive is a standing signal, not
a one-shot alarm) and clear silently when the variable recovers.

Milieu variables and default set-points (owned in
memory/hypothalamus-state.json, revisable by Juno):
- queue_depth ≤ 10 (helm health)
- deadletter_count = 0 (any dead letter is out of bounds)
- pending_total ≤ 1000 (sum of the organs' pending queues)
- vm_disk_free_pct ≥ 10
- insula cognitiveLoad ≤ 0.85, contextSaturation ≤ 0.85 (sensed by
  the insula, regulated here)

## Scripts

- `scripts/read-state.sh` — reader: prints HYPOTHALAMUS_STATE.md,
  stamps lastConsultedAt.
- `scripts/sync-state.sh` — renders the face from state.
- `scripts/regulate.sh` — the regulation pass (the organ's pipeline).
