#!/bin/bash
# Daemon entry: scheduled self-mod proposal cycle (ROADMAP M1).
#
# Runs core/self-mod/run-pipeline.sh with Juno-authored proposal generation and
# the autonomy gate (--autonomy-gate). M9 (2026-11-13): Juno is the approval
# gate — the pipeline deploys the top accepted proposal on her approval in
# any autonomy/review mode; nothing queues for human approval. A Juno
# generation failure is non-fatal — run-pipeline records it and continues with whatever
# is already queued in the store.
#
# --defer-gate is still passed for flag back-compat; under M9 the pipeline
# ignores it — the cycle always runs and never defers to the human. The
# deferral-alert block below is legacy: with no deferrals ever produced, it
# only clears a stale last-deferral.json marker left by a pre-M9 run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
# Day-gating (updated 2026-11-12): the daemon job table now has a days
# field (brain-daemon.sh), and self_mod_proposal_cycle carries |7 (Sunday,
# Pacific) there — the scheduler owns the gate, so this tick runs the cycle
# whenever it is invoked. Previously the tick self-gated to Sundays because
# the bash job table had no day field (helm port, 2026-11-08).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$WORKSPACE/core/self-mod/run-pipeline.sh" ]; then
  PIPELINE="$WORKSPACE/core/self-mod/run-pipeline.sh"
  SUITE_ROOT="$WORKSPACE"
elif [ -x "$SCRIPT_DIR/../../../core/self-mod/run-pipeline.sh" ]; then
  SUITE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  PIPELINE="$SUITE_ROOT/core/self-mod/run-pipeline.sh"
else
  echo "proposal-cycle-tick: core/self-mod/run-pipeline.sh not found" >&2
  exit 1
fi

# Ensure the stderr log directory exists before the redirect is opened
# (run-pipeline.sh creates its own dirs, but the redirect happens first).
mkdir -p "$WORKSPACE/memory/self-mod"

# M8: refresh the M7 autonomy contract from fresh evidence before the cycle
# decides — a stale autonomy-state.json must not auto-deploy (or wrongly
# block) this run. --autonomy is read-only; best-effort (never fails the tick).
KERNEL="$SUITE_ROOT/deep-brain-kernel.py"
if [ -f "$KERNEL" ]; then
  WORKSPACE="$WORKSPACE" python3 "$KERNEL" --autonomy >/dev/null 2>&1 || true
fi

# Chink check (2026-11-13, Dither-ordered): the genesis sensor runs at the
# head of every cycle, so proposal generation starts from fresh evidence of
# the gaps — chinks are the nucleation sites proposals crystallize around.
# Read-only and best-effort: a sensor failure never blocks the cycle.
CHINK_CHECK="$SUITE_ROOT/core/self-mod/chink-check.sh"
if [ -x "$CHINK_CHECK" ]; then
  WORKSPACE="$WORKSPACE" bash "$CHINK_CHECK" --workspace "$WORKSPACE" \
    >"$WORKSPACE/memory/self-mod/chink-scan.out" 2>/dev/null || true
fi

# Forward the daemon's TERM/INT (it signals only this tracked PID — Pillar 3)
# to the pipeline so a timeout-kill can't orphan a running proposal cycle.
rc=0
bash "$PIPELINE" \
  --suite-root "$SUITE_ROOT" \
  --workspace "$WORKSPACE" \
  --generate-juno \
  --autonomy-gate \
  --defer-gate \
  2>"$WORKSPACE/memory/self-mod/proposal-cycle.err" &
PIPE_PID=$!
trap 'kill "$PIPE_PID" 2>/dev/null || true' TERM INT
wait "$PIPE_PID" || rc=$?
trap - TERM INT
# Deferral alert (LEGACY, pre-M9): under M9 the pipeline never defers, so
# latest.json never carries deferred:true and this block's only live effect
# is the else branch — clearing a stale last-deferral.json marker. The
# detection branch is retained so a marker written by a pre-M9 build would
# still be surfaced rather than silently dropped.
#
# Gated on the pipeline's own rc: a deferral is a successful no-op (rc=0), and
# only a genuinely completed run may write or clear the alert. A HARD failure
# (rc!=0) must neither mint a fresh deferral signal from a stale latest.json
# nor clear an existing marker — the daemon records the failure itself.
# Everything here is best-effort; a signal write must never flip the tick's
# own exit code (set -e: every mkdir/jq guarded with || true).
if [ "$rc" -eq 0 ]; then
  LATEST="$WORKSPACE/memory/self-mod/pipeline-runs/latest.json"
  if [ -f "$LATEST" ] && [ "$(jq -r '.deferred // false' "$LATEST" 2>/dev/null || echo false)" = "true" ]; then
    DEF_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)
    DEF_AM=$(jq -r '.autonomy_mode // "steward_mode"' "$LATEST" 2>/dev/null || echo steward_mode)
    DEF_RM=$(jq -r '.review_mode // "full_review"' "$LATEST" 2>/dev/null || echo full_review)
    # 1) brain-events.jsonl signal — same shape as every other region's log-event.sh.
    mkdir -p "$WORKSPACE/memory" 2>/dev/null || true
    jq -nc --arg ts "$DEF_TS" --arg am "$DEF_AM" --arg rm "$DEF_RM" \
      '{ts:$ts, type:"self-mod", event:"cycle_deferred", autonomy_mode:$am, review_mode:$rm, reason:"steward_full_review_deferred"}' \
      >> "$WORKSPACE/memory/brain-events.jsonl" 2>/dev/null || true
    # 2) daemon-status bump: marker the kernel --status + dashboard /__daemon read.
    mkdir -p "$WORKSPACE/memory/self-mod" 2>/dev/null || true
    jq -nc --arg ts "$DEF_TS" --arg am "$DEF_AM" --arg rm "$DEF_RM" \
      '{deferred:true, at:$ts, autonomy_mode:$am, review_mode:$rm, reason:"steward_full_review_deferred"}' \
      > "$WORKSPACE/memory/self-mod/last-deferral.json.tmp" 2>/dev/null && \
      mv "$WORKSPACE/memory/self-mod/last-deferral.json.tmp" "$WORKSPACE/memory/self-mod/last-deferral.json" 2>/dev/null || true
  else
    # The cycle ran (auto_mode / relaxed_review): clear any stale deferral
    # marker so the status bar doesn't keep flagging a deferral that resolved.
    rm -f "$WORKSPACE/memory/self-mod/last-deferral.json" 2>/dev/null || true
  fi
fi

# Keep the 🛠️ Self-Mod tab fresh with the updated proposal store + streak.
[ -x "$SCRIPT_DIR/generate-dashboard.sh" ] && bash "$SCRIPT_DIR/generate-dashboard.sh" >/dev/null 2>&1 || true
if [ "$rc" -ne 0 ]; then
  echo "proposal-cycle-tick: pipeline failed — see $WORKSPACE/memory/self-mod/proposal-cycle.err" >&2
  exit 1
fi
