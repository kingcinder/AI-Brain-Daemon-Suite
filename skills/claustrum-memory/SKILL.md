---
name: claustrum-memory
description: "Cross-organ binding and coherence for the brain harness — the claustrum organ. Binds every organ's current state into one coherent workspace record (its binding section of memory/cortical.json, preserving the record's existing themes), detects cross-organ incoherence (an organ gone unread while the collective is active, a state file unreadable), and routes incoherence to the ACC. Created 2026-11-20 under Phase G (Amendment 4) of the Gated-Ingress Refactor: the coverage audit found global binding performed by dashboard/broadcast plumbing and owned by no organ — on 2026-11-14 organ state faces went stale while the organs were healthy and nothing owned that coherence."
metadata:
  openclaw:
    emoji: "🧩"
    version: "1.0.0"
    author: "Juno (Gated-Ingress Refactor, Phase G)"
    requires:
      os: ["linux"]
      bins: ["jq", "python3"]
---

# Claustrum — cross-organ binding and coherence

Biological counterpart: the **claustrum** — a thin sheet of neurons
interconnected with nearly the entire cortex, proposed as the
coordinator that binds distributed regional activity into one
coherent conscious state. Regions compute; the claustrum keeps
their states ONE state.

## Duty in this harness

Each binding pass:
1. Reads every organ's state file and binds the summaries into
   `memory/cortical.json` under its `binding` section — the record's
   existing content (broadcast themes/replays) is preserved whole;
   the claustrum owns this record now and drops nothing from it.
2. Tests coherence: an organ whose lastConsultedAt is > 26h old
   while the collective is active (median consultation < 2h), or a
   state file that cannot be parsed, is an **incoherence** —
   ledgered in `memory/binding-ledger.jsonl` and routed to the ACC
   (pattern `binding-incoherence`), whose verdict it is.
3. Updates its own state (memory/claustrum-state.json) and face
   (CORTICAL_STATE.md).

## Scripts

- `scripts/read-state.sh` — reader: prints CORTICAL_STATE.md,
  stamps lastConsultedAt in claustrum-state.json.
- `scripts/sync-state.sh` — renders the face.
- `scripts/bind.sh` — the binding pass (the organ's pipeline).
