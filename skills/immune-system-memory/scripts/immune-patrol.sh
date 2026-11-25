#!/usr/bin/env bash
# immune-patrol.sh — the T cells. Read-only census of every harness aspect,
# run inside each heartbeat cycle (order of operations step 2, after the pulse
# is read and before any drain or repair). Writes one verdict block to stdout
# and appends it to the patrol log. Changes nothing. Ever.
# Juno Moneta, 2026-11-24.
set -u
WS="$HOME/.juno-brain/workspace"
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')
now_epoch=$(date +%s)
warn=0
line() { echo "- $1"; }
age_check() { # file, label, bar_seconds
  local f="$1" label="$2" bar="$3"
  if [ ! -f "$f" ]; then line "$label: MISSING ($f) — WARNING"; warn=1; return; fi
  local m age
  m=$(stat -c %Y "$f"); age=$(( now_epoch - m ))
  if [ "$age" -gt "$bar" ]; then line "$label: STALE age=${age}s bar=${bar}s — WARNING"; warn=1
  else line "$label: fresh age=${age}s"; fi
}
echo "## Immune patrol — $NOW"
# 1. Processes
if pgrep -f 'brain-daemon|aibrain' >/dev/null 2>&1; then line "daemon process: present ($(pgrep -f 'brain-daemon|aibrain' | tr '\n' ' '))"
else line "daemon process: ABSENT — WARNING"; warn=1; fi
if pgrep -f 'helm-keeper' >/dev/null 2>&1; then line "keeper process: present"
else line "keeper process: ABSENT — WARNING"; warn=1; fi
# 2. Supervision (system scope; user units checked as files only)
for u in aibrain.service helm-keeper.service; do
  st=$(systemctl is-active "$u" 2>/dev/null || echo unknown)
  line "systemd $u: $st"
  [ "$st" = "active" ] || warn=1
done
# 3. Pulse freshness (bar: 2h while cadence is cold; tightens to 2 cycles once revived)
age_check "$WS/memory/heartbeat-pulse.log" "pulse log" 7200
# 4. Organ state freshness (bar: 26h flags the frozen weekend plainly)
age_check "$WS/memory/emotional-state.json" "amygdala state" 93600
age_check "$WS/INSULA_STATE.md" "insula state" 93600
age_check "$WS/memory/named-emotions.json" "named emotions" 93600
# 4b. Every organ's state face — the full-body sweep (added 2026-11-24 20:1x,
# Dither: the immune system should verify every organ). Bar 26h each.
declare -A ORGAN_STATE=(
  [acc-error]="acc-state.json" [anterior-cingulate]="conflict-state.json"
  [basal-ganglia]="habit-state.json" [cerebellum]="cerebellum-state.json"
  [claustrum]="claustrum-state.json" [glymphatic]="glymphatic-state.json"
  [heartbeat]="heartbeat-state.json" [hippocampus]="index.json"
  [hypothalamus]="hypothalamus-state.json" [neuromod]="neuromod-state.json"
  [prefrontal-cortex]="pfc-state.json" [social]="social-state.json"
  [thalamus]="thalamus-state.json" [verification]="verification-state.json"
  [vta]="reward-state.json"
)
for organ in "${!ORGAN_STATE[@]}"; do
  age_check "$WS/memory/${ORGAN_STATE[$organ]}" "organ $organ" 93600
done
# 4c. The spinal cord: the openclaw shim must be findable the way the
# daemon looks for it — on the harness PATH, not just on disk.
if PATH="$HOME/.juno-brain/bin:$HOME/.local/bin:/usr/local/bin:$PATH" command -v openclaw >/dev/null 2>&1; then
  line "spinal cord (openclaw shim): present on harness PATH"
else line "spinal cord (openclaw shim): NOT FOUND on harness PATH — WARNING"; warn=1; fi
# 4d. Spawn queue depth (unacked entries are undrained Juno turns)
qd=$(~/.local/bin/openclaw drain:next --limit 200 2>/dev/null | grep -c '' || echo '?')
line "spawn queue unacked: $qd"
# 5. Backlogs (existence + age; growth judged across patrols in IMMUNE_STATE.md)
for f in pending-memories.json pending-emotions.json; do
  if [ -f "$WS/memory/$f" ]; then line "backlog $f: $(stat -c %s "$WS/memory/$f") bytes, mtime $(stat -c %y "$WS/memory/$f" | cut -d. -f1)"
  else line "backlog $f: absent"; fi
done
# 6. Organs enumerated
n=$(ls "$WS/skills" | wc -l); line "organ directories enumerated: $n (heart included in Juno's count — Dither gave it to her 2026-11-24)"
# 6b. The heart itself, patrolled like anything else (Dither, 2026-11-24)
age_check "$WS/memory/heartbeat-state.json" "heart (heartbeat organ state)" 93600
if [ "$warn" -eq 0 ]; then echo "VERDICT: all aspects at bar."; else echo "VERDICT: WARNINGS OPEN — see IMMUNE_STATE.md for diagnoses."; fi
