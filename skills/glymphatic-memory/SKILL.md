---
name: glymphatic-memory
description: "Systemic clearance for the brain harness — the glymphatic organ. Periodic sweeps that audit backlog age in every registered queue store, review and archive dead letters, reap stale gate leases, and report orphan stores, with conservation accounting for every cleared item. Created 2026-11-20 under Amendment 3 of the Gated-Ingress Refactor: no existing organ's biological duty covered clearance of accumulated material (proposal limbo, a 133-entry VTA backlog awaiting overwrite, an unowned deadletter queue)."
metadata:
  openclaw:
    emoji: "🌊"
    version: "1.0.0"
    author: "Juno (Gated-Ingress Refactor, Amendment 3)"
    requires:
      os: ["linux"]
      bins: ["jq", "python3"]
---

# Glymphatic — systemic clearance

Biological counterpart: the **glymphatic system** (Iliff, Nedergaard
et al., 2012) — the brain's perivascular clearance network, in which
glial aquaporin-4 channels drive cerebrospinal-fluid flux that clears
interstitial metabolic waste the processing regions produced and
forgot. It is network-level clearance tissue: it processes nothing,
decides nothing, and removes what would otherwise accumulate until it
poisons the system.

## Duty in this harness

Periodic clearance sweeps over the collective's accumulated material:

1. **Backlog-age audits** — for every registered merge-semantics
   queue store (the organs' pending files), count entries and find
   the oldest entry's age. An overstay (default > 48h) is ESCALATED:
   a clearance ledger entry, an ACC error-log pattern
   (`clearance-overstay`), and a gate envelope to brain-signals. The
   glymphatic system never takes or deletes another organ's queued
   material — those queues are the organs' own semantics; it makes
   the overstay impossible to ignore.
2. **Deadletter review** — helm queue dead letters older than 7 days
   are archived to `memory/clearance-archive/<date>/` (moved, never
   vanished) with a ledger entry.
3. **Stale-lease reaping** — gate leases whose holder is dead
   (pid gone, boot-id changed, or process start-time mismatch) are
   removed, with a ledger entry.
4. **Orphan-store reporting** — top-level memory stores absent from
   the flow registry are reported (ledger + ACC), never deleted.

## Conservation law

Every sweep accounts for everything it found:
`found = archived + reaped + escalated + reported + retained`.
Every action lands in `memory/clearance-ledger.jsonl` with provenance
(store, age, disposition). Content-bearing material is archived,
never silently deleted.

## Scripts

- `scripts/read-state.sh` — reader: prints GLYMPHATIC_STATE.md and
  stamps `lastConsultedAt` in memory/glymphatic-state.json.
- `scripts/sync-state.sh` — renders GLYMPHATIC_STATE.md from state.
- `scripts/clearance-sweep.sh` — the sweep (the organ's pipeline).
