#!/bin/bash
# decide.sh — Executive arbitration among candidate options.
#
# Usage: decide.sh --context <label> --options '[{"id":"x","label":"...","weight":1.0}, ...]'
# Output: JSON {chosen, reasoning, scores}
#
# This is the ONE script in the brain suite that intentionally reads
# sibling state files. That's its job: synthesizing across brain regions
# is what executive function means. Every sibling read below is wrapped
# so a missing sibling just means "no adjustment from that signal" rather
# than a crash — decide.sh must work standalone too.

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$WORKSPACE/memory/pfc-state.json"

CONTEXT="general"
OPTIONS_JSON="[]"

while [[ $# -gt 0 ]]; do
  case $1 in
    --context) CONTEXT="$2"; shift 2 ;;
    --options) OPTIONS_JSON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ ! -f "$STATE_FILE" ]; then
  echo '{"chosen": null, "reasoning": "prefrontal-cortex-memory not installed"}'
  exit 1
fi

# ── Gather optional sibling signals (all best-effort, all optional) ──────────
read_field() {
  # read_field <file> <jq filter> <default>
  local file="$1" filt="$2" default="$3"
  if [ -f "$file" ]; then
    jq -r "$filt // \"$default\"" "$file" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

COGNITIVE_LOAD=$(read_field "$WORKSPACE/memory/interoceptive-state.json" '.channels.cognitiveLoad' "0.4")
SATURATION=$(read_field "$WORKSPACE/memory/interoceptive-state.json" '.channels.contextSaturation' "0.2")
GUT_SIGNAL=$(read_field "$WORKSPACE/memory/interoceptive-state.json" '.channels.gutSignal' "0.0")
DRIVE=$(read_field "$WORKSPACE/memory/reward-state.json" '.drive' "0.5")
SEEKING=$(read_field "$WORKSPACE/memory/reward-state.json" '(.seeking | length > 0) | tostring' "false")
VALENCE=$(read_field "$WORKSPACE/memory/emotional-state.json" '.dimensions.valence' "0.0")
ENERGY=$(read_field "$WORKSPACE/memory/emotional-state.json" '.dimensions.energy' "0.5")
CONFLICT_LOAD=$(read_field "$WORKSPACE/memory/conflict-state.json" '.conflictLoad' "0.0")
ERROR_PATTERNS=$(read_field "$WORKSPACE/memory/acc-state.json" '(.activePatterns | length)' "0")
HABIT_STRENGTH=$(read_field "$WORKSPACE/memory/habit-state.json" '([.habits[].strength] | if length > 0 then (add / length) else 0 end)' "0.0")
CALIBRATION=$(read_field "$WORKSPACE/memory/cerebellum-state.json" '.globalCalibration' "0.5")
OPEN_LOOPS=$(read_field "$WORKSPACE/memory/social-state.json" '([.relationships[].openLoops[]?] | length)' "0")

# ── Goals & inhibitions (PFC's own state) ────────────────────────────────────
GOALS=$(jq -c '[.goals[] | select(.status == "active")]' "$STATE_FILE")
INHIBITIONS=$(jq -c '.inhibitions' "$STATE_FILE")

# ── Semantic matching (replaces the old word-overlap heuristic when available) ─
# The heuristic is NOT deleted — it's demoted to a fallback for when the local
# LLM is unreachable, times out, or returns something that fails validation.
# This is a whole-call decision (semantic OR heuristic), not mixed per-item:
# if the LLM validly returns zero matches for a given goal, that's a real
# "no match" verdict, and falling back to the heuristic for just that one
# goal would make it ambiguous whether "no match" was a decision or an
# omission. See semantic-match.sh for the full validation contract.
SEMANTIC_METHOD="heuristic-fallback"
SEMANTIC_GOAL_MATCHES="[]"
SEMANTIC_INHIBITION_MATCHES="[]"

if [ "${PFC_SEMANTIC_MATCHING:-auto}" != "off" ] && [ -x "$SCRIPT_DIR/semantic-match.sh" ]; then
  # NOTE: must capture output+status via if/then, not a bare assignment —
  # under `set -e`, a command substitution that legitimately returns non-zero
  # (semantic-match.sh's designed fallback signal) kills the WHOLE calling
  # script right there, before the next line even runs. if/then is exempt.
  if SEMANTIC_RESULT=$("$SCRIPT_DIR/semantic-match.sh" --options "$OPTIONS_JSON" --goals "$GOALS" --inhibitions "$INHIBITIONS" 2>/tmp/pfc_semantic_err.$$); then
    SEMANTIC_STATUS=0
  else
    SEMANTIC_STATUS=$?
  fi
  if [ "$SEMANTIC_STATUS" -eq 0 ]; then
    METHOD_CHECK=$(echo "$SEMANTIC_RESULT" | jq -r '.method // empty' 2>/dev/null)
    if [ "$METHOD_CHECK" = "semantic-llm" ]; then
      SEMANTIC_METHOD="semantic-llm"
      SEMANTIC_GOAL_MATCHES=$(echo "$SEMANTIC_RESULT" | jq -c '.goal_matches // []')
      SEMANTIC_INHIBITION_MATCHES=$(echo "$SEMANTIC_RESULT" | jq -c '.inhibition_matches // []')
    fi
  fi
  rm -f /tmp/pfc_semantic_err.$$
fi

echo "$OPTIONS_JSON" > /tmp/pfc_options.$$
echo "$GOALS" > /tmp/pfc_goals.$$
echo "$INHIBITIONS" > /tmp/pfc_inhibitions.$$
echo "$SEMANTIC_GOAL_MATCHES" > /tmp/pfc_semantic_goals.$$
echo "$SEMANTIC_INHIBITION_MATCHES" > /tmp/pfc_semantic_inhibitions.$$

RESULT=$(CALIBRATION="$CALIBRATION" COGNITIVE_LOAD="$COGNITIVE_LOAD" CONFLICT_LOAD="$CONFLICT_LOAD" CONTEXT="$CONTEXT" DRIVE="$DRIVE" ENERGY="$ENERGY" ERROR_PATTERNS="$ERROR_PATTERNS" GUT_SIGNAL="$GUT_SIGNAL" HABIT_STRENGTH="$HABIT_STRENGTH" OPEN_LOOPS="$OPEN_LOOPS" SATURATION="$SATURATION" SEEKING="$SEEKING" SEMANTIC_METHOD="$SEMANTIC_METHOD" VALENCE="$VALENCE" \
  OPTIONS_FILE="/tmp/pfc_options.$$" GOALS_FILE="/tmp/pfc_goals.$$" INHIBITIONS_FILE="/tmp/pfc_inhibitions.$$" \
  SEMANTIC_GOALS_FILE="/tmp/pfc_semantic_goals.$$" SEMANTIC_INHIBITIONS_FILE="/tmp/pfc_semantic_inhibitions.$$" \
  python3 << 'PYTHON'
import os

import json, random

options = json.load(open(os.environ['OPTIONS_FILE']))
goals = json.load(open(os.environ['GOALS_FILE']))
inhibitions = json.load(open(os.environ['INHIBITIONS_FILE']))
semantic_goal_matches = json.load(open(os.environ['SEMANTIC_GOALS_FILE']))
semantic_inhibition_matches = json.load(open(os.environ['SEMANTIC_INHIBITIONS_FILE']))
using_semantic = os.environ['SEMANTIC_METHOD'] == 'semantic-llm'

cognitive_load = float(os.environ['COGNITIVE_LOAD'])
saturation = float(os.environ['SATURATION'])
gut_signal = float(os.environ['GUT_SIGNAL'])
drive = float(os.environ['DRIVE'])
seeking = os.environ['SEEKING'] == 'true'
valence = float(os.environ['VALENCE'])
energy = float(os.environ['ENERGY'])
conflict_load = float(os.environ['CONFLICT_LOAD'])
error_patterns = int(os.environ['ERROR_PATTERNS'])
habit_strength = float(os.environ['HABIT_STRENGTH'])
calibration = float(os.environ['CALIBRATION'])
open_loops = int(os.environ['OPEN_LOOPS'])

notes = []
scores = {}

STOPWORDS = {'a','an','the','to','on','of','for','and','or','your','you','is','are','it',
             'option','do','doing','this','that','with','at','in'}

def words(text):
    return {w for w in ''.join(c if c.isalnum() else ' ' for c in text.lower()).split() if w and w not in STOPWORDS}

def overlaps(a, b):
    wa, wb = words(a), words(b)
    return bool(wa) and bool(wb) and bool(wa & wb)

for opt in options:
    score = opt.get('weight', 0.5)
    oid = opt.get('id', '')
    label = (opt.get('label') or '').lower()

    # High cognitive load / context saturation: favor low-effort options
    high_effort = oid in ('project_work', 'own_projects', 'social_interaction')
    low_effort = oid in ('idle', 'dreaming', 'social_media')
    if cognitive_load > 0.65 or saturation > 0.65:
        if high_effort:
            score *= 0.6
        if low_effort:
            score *= 1.3

    # Unresolved conflicts or error patterns: bias toward dreaming/consolidation
    # (resolve what's open before starting something new)
    if (conflict_load > 0.5 or error_patterns > 2) and oid == 'dreaming':
        score *= 1.4
        notes.append('unresolved conflicts/errors favor consolidation')

    # Active drive/seeking: favor project work
    if seeking and high_effort:
        score *= 1.2
        notes.append('active seeking favors project work')
    if drive > 0.6 and oid in ('project_work', 'own_projects'):
        score *= 1.15

    # Low energy or negative mood: favor idle/low-effort
    if energy < 0.35 or valence < -0.2:
        if low_effort:
            score *= 1.25
        if high_effort:
            score *= 0.75
        notes.append('low energy/mood favors lighter options')

    # Active goals matching this option's label give it a direct boost
    if using_semantic:
        for gm in semantic_goal_matches:
            if gm.get('option_id') == oid:
                g = goals[gm['goal_index']]
                score *= (1.0 + g.get('priority', 0.5))
                notes.append(f"active goal '{g.get('description')}' boosts {oid} (semantic match)")
    else:
        for g in goals:
            desc = g.get('description') or ''
            if desc and overlaps(desc, label):
                score *= (1.0 + g.get('priority', 0.5))
                notes.append(f"active goal '{g.get('description')}' boosts {oid} (heuristic match)")

    # Inhibitions suppress matching options entirely (impulse control)
    if using_semantic:
        for im in semantic_inhibition_matches:
            if im.get('option_id') == oid:
                inh = inhibitions[im['inhibition_index']]
                score *= max(0.0, 1.0 - inh.get('strength', 0.8))
                notes.append(f"inhibition '{inh.get('pattern')}' suppresses {oid} (semantic match)")
    else:
        for inh in inhibitions:
            pat = inh.get('pattern') or ''
            if pat and (overlaps(pat, label) or overlaps(pat, oid)):
                score *= max(0.0, 1.0 - inh.get('strength', 0.8))
                notes.append(f"inhibition '{inh.get('pattern')}' suppresses {oid} (heuristic match)")

    # Habitual pull: options with above-average habit strength get a light nudge
    # (well-worn grooves are cheap to act on) — kept small since this is a
    # coarse suite-wide average, not a per-option lookup.
    if habit_strength > 0.6 and high_effort:
        score *= 1.1

    # Low execution calibration favors lower-stakes options while the agent
    # is "shaky"; high calibration is a light green light for project work.
    if calibration < 0.4 and high_effort:
        score *= 0.85
    elif calibration > 0.75 and high_effort:
        score *= 1.1

    # Open loops owed to people nudge toward social interaction if that's
    # a candidate on the table.
    if open_loops > 0 and oid == 'social_interaction':
        score *= (1.0 + min(open_loops, 5) * 0.08)
        notes.append(f'{open_loops} open loop(s) favor social_interaction')

    scores[oid] = round(score, 3)

if not scores:
    print(json.dumps({'chosen': None, 'reasoning': 'no candidate options provided', 'scores': {}, 'matching_method': 'n/a'}))
else:
    ids = list(scores.keys())
    weights = [max(0.001, scores[i]) for i in ids]
    chosen = random.choices(ids, weights=weights, k=1)[0]
    reasoning = '; '.join(notes) if notes else 'no strong signals either way — picked by relative weight'
    matching_method = 'semantic-llm' if using_semantic else 'heuristic-fallback'
    print(json.dumps({'chosen': chosen, 'reasoning': reasoning, 'scores': scores, 'context': os.environ['CONTEXT'], 'matching_method': matching_method}))
PYTHON
)

echo "$RESULT"
rm -f /tmp/pfc_options.$$ /tmp/pfc_goals.$$ /tmp/pfc_inhibitions.$$ /tmp/pfc_semantic_goals.$$ /tmp/pfc_semantic_inhibitions.$$

# Log the decision (best-effort, never block the caller on this).
# flock-guarded via safe-write.sh: this file is written on every decide.sh
# call, and decide.sh may run concurrently (e.g. heartbeat firing while
# another agent turn also calls decide.sh directly) — an unlocked
# read-modify-write here is exactly the lost-update race safe-write.sh exists
# to close. The mutation lives in a temp SCRIPT FILE rather than an inline
# `bash -c '...'` string — nesting this script's quoting inside bash -c's
# quoting inside jq's own $var syntax is a real trap (three shells' worth of
# escaping rules stacked on each other) and not worth the risk versus just
# writing a normal, single-layer script to a temp file.
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_ENTRY=$(echo "$RESULT" | jq -c --arg now "$NOW" '. + {timestamp: $now}')

if [ -x "$SCRIPT_DIR/safe-write.sh" ]; then
  MUTATE_SCRIPT=$(mktemp)
  echo "$LOG_ENTRY" > /tmp/pfc_log_entry.$$
  cat > "$MUTATE_SCRIPT" << 'MUTATE_EOF'
#!/bin/bash
set -e
ENTRY=$(cat "$PFC_LOG_ENTRY_FILE")
jq --argjson entry "$ENTRY" \
  '.decisionLog = ([$entry] + .decisionLog | .[0:30]) | .lastUpdated = $entry.timestamp' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
MUTATE_EOF
  chmod +x "$MUTATE_SCRIPT"
  PFC_LOG_ENTRY_FILE="/tmp/pfc_log_entry.$$" "$SCRIPT_DIR/safe-write.sh" "$STATE_FILE" "$MUTATE_SCRIPT" 2>/dev/null || true
  rm -f "$MUTATE_SCRIPT" /tmp/pfc_log_entry.$$
else
  jq --argjson entry "$LOG_ENTRY" '.decisionLog = ([$entry] + .decisionLog | .[0:30]) | .lastUpdated = $entry.timestamp' \
    "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" || true
fi
