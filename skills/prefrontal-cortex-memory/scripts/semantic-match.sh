#!/bin/bash
# semantic-match.sh — Ask the local LLM which goals/inhibitions are actually
# relevant to which candidate options, replacing the old bash/jq word-overlap
# heuristic (which missed real matches like "ship the project" vs "work on
# project" whenever the shared word happened to be filtered as a stopword,
# and had no real understanding of meaning beyond shared tokens).
#
# Usage:
#   semantic-match.sh --options '<json array>' --goals '<json array>' --inhibitions '<json array>'
#
# options:      [{"id": "...", "label": "..."}, ...]
# goals:        [{"description": "...", "priority": 0.0-1.0}, ...]
# inhibitions:  [{"pattern": "...", "strength": 0.0-1.0}, ...]
#
# OUTPUT (always valid JSON on stdout, regardless of success/failure):
#   {"method": "semantic-llm", "goal_matches": [...], "inhibition_matches": [...]}
#   {"method": "heuristic-fallback", "goal_matches": null, "inhibition_matches": null}
#
# EXIT CODE: 0 if a validated semantic match was produced, 1 if the caller
# should fall back to its own heuristic. Callers should check BOTH the exit
# code and the "method" field before trusting goal_matches/inhibition_matches
# — this script fails closed on anything it can't fully validate: connection
# failure, timeout, malformed JSON, or a response that references an option
# id / array index that doesn't actually exist in what was sent.
#
# CALLER WARNING (set -e): if your caller has `set -e` and captures this
# script's output via command substitution, e.g. `X=$(semantic-match.sh ...)`,
# that line WILL kill the caller's entire script the instant this script
# returns its designed fallback exit code 1 — set -e treats a failed command
# substitution as a failed command, and by default a plain assignment isn't
# an exempted context. Wrap the call in an if/then to capture output and
# status safely:
#   if RESULT=$(semantic-match.sh ...); then STATUS=0; else STATUS=$?; fi
#
# ENV: uses the same LLM_BASE_URL / LLM_MODEL / LLM_TIMEOUT / LLM_RETRIES
# overrides as llm-call.sh, so one local-server config covers every caller
# in the suite. Defaults favor NOT blocking a decision for long: local
# inference on modest hardware can take several seconds even for a short
# structured answer, so the default timeout is generous, but callers must
# never treat a slow/absent model as a hard failure of the whole decision.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LLM_CALL="$SCRIPT_DIR/llm-call.sh"

OPTIONS_JSON="[]"
GOALS_JSON="[]"
INHIBITIONS_JSON="[]"

while [[ $# -gt 0 ]]; do
  case $1 in
    --options) OPTIONS_JSON="$2"; shift 2 ;;
    --goals) GOALS_JSON="$2"; shift 2 ;;
    --inhibitions) INHIBITIONS_JSON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

fallback() {
  echo '{"method": "heuristic-fallback", "goal_matches": null, "inhibition_matches": null}'
  exit 1
}

# Nothing to match against an LLM for — skip the call entirely, not even worth the latency.
GOAL_COUNT=$(echo "$GOALS_JSON" | jq 'length' 2>/dev/null || echo 0)
INHIBITION_COUNT=$(echo "$INHIBITIONS_JSON" | jq 'length' 2>/dev/null || echo 0)
OPTION_COUNT=$(echo "$OPTIONS_JSON" | jq 'length' 2>/dev/null || echo 0)

if [ "$OPTION_COUNT" -eq 0 ] || { [ "$GOAL_COUNT" -eq 0 ] && [ "$INHIBITION_COUNT" -eq 0 ]; }; then
  fallback
fi

if [ ! -x "$LLM_CALL" ]; then
  echo "⚠️  semantic-match.sh: llm-call.sh not found — falling back to heuristic" >&2
  fallback
fi

SYSTEM_PROMPT='You are a strict JSON classification function with no conversational output. You match goals and inhibitions to candidate options by MEANING, not by shared words. Output ONLY a single JSON object matching the exact schema given. No prose, no markdown code fences, no explanation — JSON only.'

USER_PROMPT=$(jq -n --argjson options "$OPTIONS_JSON" --argjson goals "$GOALS_JSON" --argjson inhibitions "$INHIBITIONS_JSON" '
"Options (0-indexed by position, match using the exact \"id\" field):\n" +
(($options | to_entries) | map("  [\(.key)] id=\"\(.value.id)\" label=\"\(.value.label)\"") | join("\n")) +
"\n\nGoals (0-indexed):\n" +
(if ($goals | length) > 0 then (($goals | to_entries) | map("  [\(.key)] \"\(.value.description)\" (priority \(.value.priority))") | join("\n")) else "  (none)" end) +
"\n\nInhibitions (0-indexed):\n" +
(if ($inhibitions | length) > 0 then (($inhibitions | to_entries) | map("  [\(.key)] \"\(.value.pattern)\" (strength \(.value.strength))") | join("\n")) else "  (none)" end) +
"\n\nFor each goal, decide which option(s) it is CLEARLY, semantically about accomplishing or making progress on — not vague or tangential relevance. A goal may match zero, one, or several options. Same for each inhibition: which option(s) it should suppress because doing that option would trigger the exact pattern being avoided.\n\nRespond with ONLY this JSON shape, using the goal/inhibition index numbers shown above and the exact option id strings shown above:\n{\"goal_matches\": [{\"goal_index\": 0, \"option_id\": \"...\"}], \"inhibition_matches\": [{\"inhibition_index\": 0, \"option_id\": \"...\"}]}\nIf nothing matches, use empty arrays. Output nothing but the JSON object."
')

RAW_OUTPUT=$("$LLM_CALL" --system "$SYSTEM_PROMPT" --user "$USER_PROMPT" \
  --timeout "${LLM_TIMEOUT:-20}" --retries "${LLM_RETRIES:-1}" --json 2>/tmp/semantic-match-err.$$)
LLM_STATUS=$?

if [ "$LLM_STATUS" -ne 0 ]; then
  echo "⚠️  semantic-match.sh: local LLM call failed — $(cat /tmp/semantic-match-err.$$ 2>/dev/null | tail -1)" >&2
  rm -f /tmp/semantic-match-err.$$
  fallback
fi
rm -f /tmp/semantic-match-err.$$

# Some local servers/models wrap JSON in ```json fences even in JSON mode — strip if present.
CLEANED=$(echo "$RAW_OUTPUT" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

if ! echo "$CLEANED" | jq -e 'has("goal_matches") and has("inhibition_matches")' > /dev/null 2>&1; then
  echo "⚠️  semantic-match.sh: response wasn't valid JSON with the expected keys — falling back" >&2
  fallback
fi

# Strict validation: every referenced index and option_id must actually exist
# in what we sent. Anything else (hallucinated id, out-of-range index, wrong
# type) is dropped — never apply a partially-trusted result wholesale. Note:
# `inside()` is NOT array-membership-check in jq despite how it reads — it
# gave false positives for values that were NOT in the array. The correct
# idiom is capturing the value into a variable, then `any(. == $that_var)`
# over the candidate array.
VALIDATED=$(echo "$CLEANED" | jq -c --argjson options "$OPTIONS_JSON" --argjson goalCount "$GOAL_COUNT" --argjson inhCount "$INHIBITION_COUNT" '
  ($options | map(.id)) as $validIds |
  {
    goal_matches: [ .goal_matches[]? | select(
        (.goal_index | type == "number") and (.goal_index >= 0) and (.goal_index < $goalCount) and
        (.option_id | type == "string") and (.option_id as $oid | ($validIds | any(. == $oid)))
      ) ],
    inhibition_matches: [ .inhibition_matches[]? | select(
        (.inhibition_index | type == "number") and (.inhibition_index >= 0) and (.inhibition_index < $inhCount) and
        (.option_id | type == "string") and (.option_id as $oid | ($validIds | any(. == $oid)))
      ) ]
  }
' 2>/dev/null)

if [ -z "$VALIDATED" ]; then
  echo "⚠️  semantic-match.sh: validation pass itself failed (malformed structure) — falling back" >&2
  fallback
fi

echo "$VALIDATED" | jq -c '{method: "semantic-llm"} + .'
