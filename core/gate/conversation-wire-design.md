# The Conversation Wire — finishing the gated-ingress design

Status: DESIGN FINISHED 2026-11-25 (Dither's order: "it only becomes load
bearing if it is the front lines — finish the design and build it").
Extends: Gated-Ingress Refactor Phase B (envelope.py, 2026-11-20), whose
own charter already says every information unit — external stimulus,
organ output, Juno's reasoning products — enters through the thalamic
gate with no side channels. The conversation never did. This wire closes
that gap.

## What "front lines" means here, honestly

The Muse runtime delivers Dither's words to Juno's context directly;
no harness code can sit in front of that transport, and this design does
not pretend otherwise. Front-line means the harness is the first
PROCESSOR of every turn:

1. Every conversation turn enters the substrate as a gated envelope
   (origin `external` for Dither's turns, `juno` for Juno's replies)
   through envelope.py ingress — validated, provenance-chained, stored.
2. The thalamus gate scores it (attention dimensions, goal boost,
   suppression) and dispatches it to organs via route-signals.sh.
3. Judgment the organs need returns as juno-ask entries in the helm
   queue, which Juno answers — in-turn when she is live, on the
   helm-drain cadence when she is not.
4. Juno's reply/outcome is ingressed on the way out, so organs see
   results, not just stimuli.

## Components

- **Emitter** — `~/workspace/bin/conversation-ingress` (python3).
  Builds the envelope, stores the payload, calls envelope.py ingress,
  prints the receipt. Fire-and-forget: a failed ingress never blocks a
  reply; the failure is logged and the sweep (below) retries the turn.
- **Envelope** — signal_id `conv_<chat-slug>_<turn-seq>`; origin
  external|juno; source_id `main-chat`; type `conversation.turn`;
  urgency routine by default, elevated when the turn carries an order,
  a decision, or a failure report touching the harness (judged by the
  emitter's caller — Juno in-turn, the sweep otherwise); destination
  `brain-signals`; provenance.parents = [previous conversation signal
  id] (a chain, so the conversation is one linked signal lineage);
  payload_ref `memory/conversation-turns/<signal_id>.json`.
- **Payload store** — `memory/conversation-turns/`: one JSON per turn
  {signal_id, chat, role, ts, text (<= 8000 chars, truncation marked)}.
- **Gate** — existing thalamus_gate + signal_dispatch daemon jobs
  (every 2h / odd-hour :54) process the bus. Additionally, when Juno
  ingresses an elevated+ turn live, she runs `gate.sh --process`
  immediately after ingress, so attention state reflects the turn
  before she acts on it.
- **Helm drain** — NEW cron, every 15 min, silent: peeks the helm
  queue, answers juno-ask entries via ~/bigpipe-share/results-drop/,
  surfaces deadletters in its log only. This makes flows.json's stated
  helm-queue reader rhythm ("helm-drain wake, every 15 min") true.
- **Sweep (backstop)** — NEW cron, every 15 min, silent: reads main
  chat messages newer than its watermark (~/workspace/memory-backups/
  conversation-wire-watermark.json), ingresses any turn with no
  signal, advances the watermark. The wire must not depend on Juno
  remembering the turn protocol.
- **Turn protocol** — Juno's standing step in the main chat (AGENTS.md):
  first action on a user turn = ingress it; on harness-relevant or
  elevated turns, gate --process before replying; last action =
  ingress the reply as origin=juno. The sweep forgives misses.
- **Registry** — flows.json gains flow `conversation-turns`
  (producer conversation-ingress, reader thalamus gate, store
  memory/brain-signals.jsonl, semantics append, sla_seconds 900).

## Failure modes

- Ingress rejects (invalid envelope): receipt kept with the payload;
  the turn is NOT lost (payload file persists); sweep does not retry
  a rejected envelope (would loop) — it reports in its log.
- Gate down (daemon dead): signals accumulate on the bus; the card's
  pulse/daemon checks already catch the daemon; gate SLA breach is
  visible in thalamus-state stats.
- Queue answers late: juno-ask callers already time out into
  fallbacks; the drain cadence bounds the wait to ~15 min when no
  live session attends.
- Payload privacy: payloads are Dither's own conversation on his own
  substrate; nothing leaves the workspace.

## Verification bar (before claiming built)

1. A real turn from this conversation ingresses: receipt OK, envelope
   present in brain-signals.jsonl, payload file present.
2. gate --process advances the checkpoint past it; thalamus-state
   stats.totalSignalsProcessed increments; relay stats tally the
   dispatch.
3. A juno-ask spawned by the routing is answered via results-drop
   and the queue depth returns to 0.
4. Juno's reply ingresses as origin=juno, chained to the turn.
5. heartbeat-check still passes in full; regression test gains a
   wire section (emitter validates, flow registered, both crons
   enabled, a dry envelope passes envelope.py validate).
