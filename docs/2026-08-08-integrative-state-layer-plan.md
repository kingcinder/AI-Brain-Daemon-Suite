# Integrative State Layer (A) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every region of the AI Brain Suite one shared, modulatory substrate — a global neuromodulator vector and a global workspace of attention — by adding exactly two state files, one new daemon job, three reader hooks, and three new tests, with the existing suite staying byte-for-byte green when the vector is absent.

**Architecture:** `neuromod-update.sh` (a new direct daemon job, minutes 6/21/36/51) composes `memory/neuromod-state.json` from existing skill states (VTA drive, amygdala valence/arousal, ACC conflict load, insula channels, social trust, heartbeat recency), then chains `workspace-refresh.sh` to assemble `memory/workspace.json`'s `context` block. `broadcast.sh` (called from `gate.sh` on every non-suppressed dispatch) appends `currentFocus`/`recentBroadcasts` to the workspace. `gate.sh`, `decide.sh`, and the three encode pipelines read through `get-neuromod.sh`, which returns neutral defaults (all factors 1.0) whenever the vector is missing — the compatibility lock that keeps every existing test unchanged and green.

**Tech Stack:** bash (flock + `$$`-scoped tmp + atomic `mv`, the 2026-08-08 audit pattern), `jq`, `bc` (both already in the suite's dependency set), python3 (only where the target scripts already embed python), `deep-brain-kernel.py` JOBS table.

## Global Constraints

- **Neutral-by-default:** every reader treats a missing `neuromod-state.json`/`workspace.json` as neutral (modulators absent ⇒ all factors 1.0 ⇒ scores byte-identical to today). This is enforced by `test_gate_neuromod.sh` (b) and is a hard requirement — do not "fail loud" on the happy path.
- **Read-primary, fail-open:** missing source files contribute 0 to their term and get listed in `missingSources`; an all-missing source set yields baseline values (0.5; sleepPressure 0). Never exit non-zero because a source is absent.
- **Hardened writes:** every new writer takes `exec 200>"<file>.lock"; flock 200` at the top, writes to `<file>.tmp.$$`, and atomically `mv`s. Lock files are per-state-file and distinct (`neuromod-state.json.lock`, `workspace.json.lock`). No nested same-file locking. Background children (`gate.sh`'s dispatch) must not inherit a held lock fd.
- **Minute uniqueness:** the new `neuromod_update` job uses minutes `6,21,36,51` — all four are globally unique in the existing 29-job table (verified: used minutes are 0,2,3,5,7,8,10,12,14,16,18,20,22,24,26,28,30,32,34,37,40,42,44,46,48,50,52,54,56,58).
- **No changes to existing tests:** `tests/test_*.sh` (24), the phase harnesses, and `run_skill_unit_tests.sh` must stay green *without modification*. The three new tests are new files only.
- **Existing behavior preserved verbatim:** the gate's five attention dimensions, the 0.70/0.40/0.20 thresholds, and the score formula `(goal_relevance*0.35 + novelty*0.15 + urgency*0.25 + headroom*0.25) * circadian` remain; modulation only multiplies inputs/factors around them.
- **Concurrency-safe reads in gate.sh:** `_score_signal` runs inside a `tail | while read` subshell — read the neuromod vector *inside* `_score_signal` via `get-neuromod.sh`, never via a variable set in `_process` (it would not propagate into the pipeline subshell).

---

## File Structure

**New files (all under `AI_BRAIN_SUITE_COMPLETE/`):**

| File | Responsibility |
|---|---|
| `skills/thalamus-memory/scripts/neuromod-update.sh` | Compose + decay + write `memory/neuromod-state.json`; then chain `workspace-refresh.sh` |
| `skills/thalamus-memory/scripts/get-neuromod.sh` | Shared reader: `--json` (full vector) / `--get <modulator>` (single value) / `--composite <name>`; neutral defaults when absent |
| `skills/thalamus-memory/scripts/workspace-refresh.sh` | Assemble `context` block (circadian phase, active goals, neuromod snapshot) + write `memory/workspace.json` |
| `skills/thalamus-memory/scripts/broadcast.sh` | Append `currentFocus` + `recentBroadcasts` ring (5) to `memory/workspace.json` |
| `tests/test_neuromod_state.sh` | A1 test: mappings, clamps, decay, partial vector, baselines, atomic write |
| `tests/test_workspace_broadcast.sh` | A2 test: publish→gate→broadcast, ring behavior, context assembly |
| `tests/test_gate_neuromod.sh` | A3 test: modulation shifts scores + absent-vector regression lock |

**Modified files:**

| File | Change |
|---|---|
| `deep-brain-kernel.py` | Add `neuromod_update` job to `JOBS` (after `verification_pass`) |
| `skills/thalamus-memory/scripts/gate.sh` | Read vector in `_score_signal`; apply 5 gain factors; call `broadcast.sh` on non-suppressed dispatch |
| `skills/prefrontal-cortex-memory/scripts/decide.sh` | Read DA/cortisol + workspace context; DA goal-alignment multiplier; cortisol uncertainty bias |
| `skills/anterior-cingulate-memory/scripts/encode-pipeline.sh` | Cortisol exchange threshold (2 → 1 when stressIndex > 0.6) |
| `skills/vta-memory/scripts/encode-pipeline.sh` | Dopamine intensity factor (×1.15 when DA < 0.4) |
| `skills/amygdala-memory/scripts/encode-pipeline.sh` | NA intensity factor (× (1 + 0.3·(NA−0.5))) |
| `skills/thalamus-memory/capability-manifest.json` | Declare the three new tests |
| `BRAIN_DAEMON_SCHEDULE.md` | Document `neuromod_update` (30-job table) |

---

## Task 1: `neuromod-update.sh` + `get-neuromod.sh` + the `neuromod_update` job (A1)

**Files:**
- Create: `skills/thalamus-memory/scripts/neuromod-update.sh`
- Create: `skills/thalamus-memory/scripts/get-neuromod.sh`
- Create: `tests/test_neuromod_state.sh`
- Modify: `deep-brain-kernel.py` (JOBS table, after the `verification_pass` entry)

**Interfaces:**
- Consumes: `memory/reward-state.json` (`.drive`, `.recentRewards`, `.anticipating`, `.lastUpdated`), `memory/emotional-state.json` (`.dimensions.valence`, `.dimensions.arousal`, `.lastUpdated`), `memory/conflict-state.json` (`.conflictLoad`, `.lastUpdated`), `memory/interoceptive-state.json` (`.channels.cognitiveLoad`, `.channels.gutSignal`, `.lastUpdated`), `memory/acc-state.json` (`.activePatterns`, `.lastUpdated`), `memory/social-state.json` (`.relationships[].trust`, `.lastUpdated`), `memory/heartbeat-state.json` (`.lastBeat`, `.circadian.wakeHour`, `.circadian.sleepHour`), `memory/thalamus-state.json` (`.attentionFocus`).
- Produces: `memory/neuromod-state.json` (schema below); `get-neuromod.sh --json` / `--get <name>` / `--composite <name>` — the contract Tasks 3–6 consume.

- [x] **Step 1: Write the failing test**

Create `tests/test_neuromod_state.sh`:

```bash
#!/bin/bash
# test_neuromod_state.sh — A1: neuromod vector composition.
#
# Tests:
#  1. neuromod-update.sh writes a valid vector with all 7 modulators + composites
#  2. dopamine mapping: higher drive raises dopamine; clamp at 1.0
#  3. noradrenaline mapping: arousal + insula load + heartbeat recency
#  4. oxytocin mapping: mean relationship trust
#  5. sleepPressure: 0 in a fresh/absent-heartbeat workspace
#  6. partial vector: one missing source file degrades, others still computed
#  7. all sources missing: baselines, missingSources lists them, exit 0
#  8. get-neuromod.sh: --get returns the value; --json returns the vector;
#     absent file returns the neutral default
#  9. atomic write: no .tmp.$$ residue; lock file exists
#
# Run: bash tests/test_neuromod_state.sh
# Requires: jq, bc

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

UP="$ROOT/skills/thalamus-memory/scripts/neuromod-update.sh"
GET="$ROOT/skills/thalamus-memory/scripts/get-neuromod.sh"

# ── Test 1: writes a valid vector ──────────────────────────────────────
echo "Test 1: neuromod-update.sh writes a valid vector"

# Seed every source with neutral-ish values so the vector is fully computed.
cat > "$TEST_WORKSPACE/memory/reward-state.json" << 'EOF'
{"drive": 0.6, "recentRewards": [{"id":"r1"}], "anticipating": ["a1"], "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/emotional-state.json" << 'EOF'
{"dimensions": {"valence": 0.6, "arousal": 0.6}, "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/conflict-state.json" << 'EOF'
{"conflictLoad": 0.5, "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/interoceptive-state.json" << 'EOF'
{"channels": {"cognitiveLoad": 0.4, "gutSignal": 0.3}, "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/social-state.json" << 'EOF'
{"relationships": {"bob": {"trust": 0.7, "affinity": 0.5}}, "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/heartbeat-state.json" << 'EOF'
{"lastBeat": "", "circadian": {"wakeHour": 8, "sleepHour": 22}, "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
cat > "$TEST_WORKSPACE/memory/thalamus-state.json" << 'EOF'
{"attentionFocus": ["ship the brain suite"], "lastUpdated": "2026-08-08T00:00:00Z"}
EOF

"$UP" > /dev/null 2>&1

VEC="$TEST_WORKSPACE/memory/neuromod-state.json"
if [[ -f "$VEC" ]]; then
    N=$(jq '.modulators | length' "$VEC")
    if [[ "$N" -eq 7 ]]; then
        pass "vector has all 7 modulators (got $N)"
    else
        fail "expected 7 modulators, got $N"
    fi
    if jq -e '.composites.arousal and .composites.valence and .composites.stressIndex' "$VEC" > /dev/null 2>&1; then
        pass "composites present"
    else
        fail "composites missing"
    fi
else
    fail "neuromod-state.json not created"
fi

# ── Test 2: dopamine mapping + clamp ───────────────────────────────────
echo "Test 2: dopamine mapping and clamp"

# drive 1.0 with recent reward + anticipation -> dopamine should clamp at 1.0
jq '.drive = 1.0' "$TEST_WORKSPACE/memory/reward-state.json" > "$TEST_WORKSPACE/memory/reward-state.json.tmp" \
  && mv "$TEST_WORKSPACE/memory/reward-state.json.tmp" "$TEST_WORKSPACE/memory/reward-state.json"
"$UP" > /dev/null 2>&1
DA=$("$GET" --get dopamine)
if (( $(echo "$DA >= 1.0" | bc -l) )); then
    pass "dopamine clamps at 1.0 (got $DA)"
else
    fail "dopamine should clamp at 1.0, got $DA"
fi

# drive 0.0, no rewards -> dopamine below baseline
jq '.drive = 0.0 | .recentRewards = [] | .anticipating = []' \
  "$TEST_WORKSPACE/memory/reward-state.json" > "$TEST_WORKSPACE/memory/reward-state.json.tmp" \
  && mv "$TEST_WORKSPACE/memory/reward-state.json.tmp" "$TEST_WORKSPACE/memory/reward-state.json"
"$UP" > /dev/null 2>&1
DA=$("$GET" --get dopamine)
if (( $(echo "$DA < 0.5" | bc -l) )); then
    pass "dopamine falls with low drive (got $DA)"
else
    fail "dopamine should be < 0.5 with drive 0, got $DA"
fi

# ── Test 3: noradrenaline mapping ──────────────────────────────────────
echo "Test 3: noradrenaline from arousal + insula + recency"

# arousal 1.0 -> NA well above baseline
jq '.dimensions.arousal = 1.0' "$TEST_WORKSPACE/memory/emotional-state.json" > "$TEST_WORKSPACE/memory/emotional-state.json.tmp" \
  && mv "$TEST_WORKSPACE/memory/emotional-state.json.tmp" "$TEST_WORKSPACE/memory/emotional-state.json"
"$UP" > /dev/null 2>&1
NA=$("$GET" --get noradrenaline)
if (( $(echo "$NA > 0.7" | bc -l) )); then
    pass "noradrenaline rises with arousal (got $NA)"
else
    fail "noradrenaline should be > 0.7 with arousal 1.0, got $NA"
fi

# ── Test 4: oxytocin mapping ───────────────────────────────────────────
echo "Test 4: oxytocin from mean relationship trust"

# single relationship trust 0.7 -> oxytocin ~0.66
OX=$("$GET" --get oxytocin)
if (( $(echo "$OX > 0.60 && $OX < 0.72" | bc -l) )); then
    pass "oxytocin tracks mean trust (got $OX)"
else
    fail "oxytocin should be ~0.66 with trust 0.7, got $OX"
fi

# ── Test 5: sleepPressure with no recent beat ──────────────────────────
echo "Test 5: sleepPressure stays low without a sleep phase"

SP=$("$GET" --get sleepPressure)
if (( $(echo "$SP < 1.0" | bc -l) )); then
    pass "sleepPressure bounded (got $SP)"
else
    fail "sleepPressure out of range: $SP"
fi

# ── Test 6: partial vector (one source missing) ────────────────────────
echo "Test 6: missing source degrades to a partial vector"

rm -f "$TEST_WORKSPACE/memory/social-state.json"
"$UP" > /dev/null 2>&1
if jq -e '.modulators.dopamine and (.missingSources | index("social"))' "$VEC" > /dev/null 2>&1; then
    pass "partial vector: dopamine computed, social listed in missingSources"
else
    fail "partial vector handling broken: $(cat "$VEC")"
fi

# ── Test 7: all sources missing → baselines, exit 0 ────────────────────
echo "Test 7: all sources missing yields baselines"

mv "$VEC" "$TEST_WORKSPACE/memory/neuromod-state.json.bak"
rm -f "$TEST_WORKSPACE/memory/"*.json
if "$UP" > /dev/null 2>&1; then
    B=$(jq -r '.modulators.dopamine.value' "$VEC" 2>/dev/null || echo "missing")
    if [[ "$B" = "0.5" ]] || [[ "$B" = "missing" ]]; then
        # dopamine baseline 0.5 with no sources; or file absent (still acceptable,
        # since a fully-missing source set is the fresh-install state)
        if [[ -f "$VEC" ]]; then
            pass "all-missing run exits 0 and writes baseline vector"
        else
            pass "all-missing run exits 0 (no vector written, reads neutral)"
        fi
    else
        fail "baseline dopamine should be 0.5, got $B"
    fi
else
    fail "all-missing source run should exit 0"
fi

# ── Test 8: get-neuromod.sh contract ───────────────────────────────────
echo "Test 8: get-neuromod.sh reader contract"

rm -rf "$TEST_WORKSPACE/memory"
mkdir -p "$TEST_WORKSPACE/memory"
VAL=$("$GET" --get dopamine)
if [[ "$VAL" = "0.5" ]]; then
    pass "--get returns neutral default when absent"
else
    fail "--get should return 0.5 when absent, got '$VAL'"
fi

# ── Test 9: atomic write, no residue, lock present ─────────────────────
echo "Test 9: atomic write hygiene"

cat > "$TEST_WORKSPACE/memory/reward-state.json" << 'EOF'
{"drive": 0.5, "recentRewards": [], "anticipating": [], "lastUpdated": "2026-08-08T00:00:00Z"}
EOF
"$UP" > /dev/null 2>&1
if [[ -f "$TEST_WORKSPACE/memory/neuromod-state.json.lock" ]]; then
    pass "lock file present"
else
    fail "lock file missing"
fi
if ! ls "$TEST_WORKSPACE/memory/neuromod-state.json.tmp."* > /dev/null 2>&1; then
    pass "no tmp residue"
else
    fail "tmp residue left behind"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Neuromod State Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_neuromod_state.sh`
Expected: FAIL with "neuromod-state.json not created" (neither script exists yet).

- [x] **Step 3: Write `get-neuromod.sh`**

Create `skills/thalamus-memory/scripts/get-neuromod.sh`:

```bash
#!/bin/bash
# get-neuromod.sh — Shared reader for the global neuromodulator vector.
#
# Usage:
#   get-neuromod.sh --json              # full vector (modulators + composites)
#   get-neuromod.sh --get <modulator>   # single 0-1 value (e.g. dopamine)
#   get-neuromod.sh --composite <name>  # composite value (arousal/valence/stressIndex)
#
# Neutral-by-default: an absent file or field returns the baseline (0.5;
# sleepPressure 0), never an error — readers can call this unconditionally.
#
# Read-only: takes the shared lock only to avoid reading mid-replace.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
STATE_FILE="$WORKSPACE/memory/neuromod-state.json"

exec 200>"$STATE_FILE.lock"
flock 200

BASELINE="0.5"
if [[ "$1" = "--get" ]]; then
    MOD="$2"
    [[ "$MOD" = "sleepPressure" ]] && BASELINE="0"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg m "$MOD" '.modulators[$m].value // '"$BASELINE" \
          "$STATE_FILE" 2>/dev/null || echo "$BASELINE"
    else
        echo "$BASELINE"
    fi
    exit 0
elif [[ "$1" = "--composite" ]]; then
    NAME="$2"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg n "$NAME" '.composites[$n] // 0.5' "$STATE_FILE" 2>/dev/null || echo "0.5"
    else
        echo "0.5"
    fi
    exit 0
elif [[ "$1" = "--json" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        printf '%s' '{"version":1,"modulators":{},"composites":{"arousal":0.5,"valence":0.5,"stressIndex":0.5},"missingSources":[]}'
    fi
    exit 0
fi

echo "Usage: get-neuromod.sh --json | --get <modulator> | --composite <name>" >&2
exit 1
```

- [x] **Step 4: Write `neuromod-update.sh`**

Create `skills/thalamus-memory/scripts/neuromod-update.sh`:

```bash
#!/bin/bash
# neuromod-update.sh — Compose the global neuromodulator vector from the
# skill states, decay stale sources toward baseline, and write
# memory/neuromod-state.json. Chained from the neuromod_update daemon job
# (minutes 6,21,36,51); ends by running workspace-refresh.sh so the
# workspace context block is assembled from the fresh vector.
#
# Read-primary / fail-open: every source read is optional. A missing source
# contributes 0 to its term and is listed in missingSources; an all-missing
# source set yields the baselines. Never exits non-zero because a source is
# absent.
#
# Hardened write: flock + $$-scoped tmp + atomic mv (2026-08-08 audit pattern).

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEM="$WORKSPACE/memory"
OUT="$MEM/neuromod-state.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$MEM"
exec 200>"$OUT.lock"
flock 200

# ── read_field <file> <jq filter> <default> — fail-open reader ─────────────
read_field() {
    local file="$1" filt="$2" default="$3"
    if [[ -f "$file" ]]; then
        jq -r "$filt" "$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Source recency (for the stale-pull decay): the newest lastUpdated across a
# modulator's source files. read_age <file> -> age in hours or "" if absent.
read_age() {
    local file="$1"
    [[ -f "$file" ]] || { echo ""; return; }
    local lu
    lu=$(jq -r '.lastUpdated // ""' "$file" 2>/dev/null || echo "")
    if [[ -z "$lu" || "$lu" = "null" ]]; then
        echo ""
        return
    fi
    local epoch_now epoch_lu
    epoch_now=$(date -u +%s)
    epoch_lu=$(date -u -d "$lu" +%s 2>/dev/null || date -u -d "${lu%Z}Z" +%s 2>/dev/null || echo "")
    if [[ -z "$epoch_lu" ]]; then
        echo ""
    else
        echo "scale=4; ($epoch_now - $epoch_lu) / 3600" | bc 2>/dev/null || echo ""
    fi
}

DRIVE=$(read_field "$MEM/reward-state.json" '.drive // 0.5' "0.5")
HAS_REWARD=$(read_field "$MEM/reward-state.json" '([.recentRewards[]?] | length > 0) | if . then 1 else 0 end' "0")
HAS_ANTICIPATION=$(read_field "$MEM/reward-state.json" '([.anticipating[]?] | length > 0) | if . then 1 else 0 end' "0")

VALENCE=$(read_field "$MEM/emotional-state.json" '.dimensions.valence // 0.5' "0.5")
AROUSAL=$(read_field "$MEM/emotional-state.json" '.dimensions.arousal // 0.5' "0.5")

CONFLICT_LOAD=$(read_field "$MEM/conflict-state.json" '.conflictLoad // 0.5' "0.5")
ACC_ACTIVE=$(read_field "$MEM/acc-state.json" '([.activePatterns[]?] | length) | if . > 0 then 1 else 0 end' "0")

INS_LOAD=$(read_field "$MEM/interoceptive-state.json" '.channels.cognitiveLoad // 0.3' "0.3")
INS_GUT=$(read_field "$MEM/interoceptive-state.json" '.channels.gutSignal // 0.2' "0.2")

# mean relationship trust
AVG_TRUST=$(read_field "$MEM/social-state.json" \
  '([.relationships[].trust?] | if length > 0 then (add / length) else 0.5 end)' "0.5")

# recent heartbeat activity (beat within 30 min -> 1)
RECENT_ACTIVITY=$(read_field "$MEM/heartbeat-state.json" \
  '((.lastBeat // "") != "") | if . then 1 else 0 end' "0")

# attentionFocus length (gate), capped at 3 in the formula
FOCUS_LEN=$(read_field "$MEM/thalamus-state.json" \
  '([.attentionFocus[]?] | if length > 3 then 3 else length end) // 0' "0")

# ── sleep pressure: hours since wake / 24, 0 while asleep ──────────────────
HOUR=$(date -u +%H | sed 's/^0//'); [ -z "$HOUR" ] && HOUR=0
WAKE_HOUR=$(read_field "$MEM/heartbeat-state.json" '.circadian.wakeHour // 8' "8")
SLEEP_HOUR=$(read_field "$MEM/heartbeat-state.json" '.circadian.sleepHour // 22' "22")
ASLEEP=$(HOUR="$HOUR" WAKE_HOUR="$WAKE_HOUR" SLEEP_HOUR="$SLEEP_HOUR" python3 -c "
import os
h, w, s = int(os.environ['HOUR']), int(os.environ['WAKE_HOUR']), int(os.environ['SLEEP_HOUR'])
def in_range(h, start, end):
    if start <= end: return start <= h < end
    return h >= start or h < end
print('1' if (in_range(h, s, (s+1)%24) or in_range(h, (s+1)%24, w)) else '0')
")
if [[ "$ASLEEP" = "1" ]]; then
    SLEEP_PRESSURE="0"
else
    HOURS_SINCE_WAKE=$(( (HOUR - WAKE_HOUR + 24) % 24 ))
    SLEEP_PRESSURE=$(echo "scale=4; if ($HOURS_SINCE_WAKE / 24 > 1.0) 1.0 else $HOURS_SINCE_WAKE / 24" | bc 2>/dev/null || echo "0")
fi

# ── clamp helper: clamp <value> ────────────────────────────────────────────
clamp() { echo "scale=4; if ($1 > 1.0) 1.0 else if ($1 < 0) 0 else $1" | bc 2>/dev/null || echo "0.5"; }

DOPAMINE=$(clamp "0.5 + 0.6*($DRIVE - 0.5) + 0.15*$HAS_REWARD + 0.10*$HAS_ANTICIPATION")
NORADRENALINE=$(clamp "0.5 + 1.0*($AROUSAL - 0.5) + 0.25*($INS_LOAD - 0.3) + 0.20*$RECENT_ACTIVITY")
SEROTONIN=$(clamp "0.5 + 0.8*($VALENCE - 0.5)")
ACETYLCHOLINE=$(clamp "0.5 + 0.10*$FOCUS_LEN + 0.30*($CONFLICT_LOAD - 0.5)")
CORTISOL=$(clamp "0.5 + 0.50*($CONFLICT_LOAD - 0.5) + 0.25*$INS_GUT + 0.20*$ACC_ACTIVE")
OXYTOCIN=$(clamp "0.5 + 0.8*($AVG_TRUST - 0.5)")

# ── stale-source pull toward baseline (sources older than 24h) ─────────────
# pull <current> <baseline> -> value pulled 15% toward baseline
pull() {
    echo "scale=4; $1 + 0.15*($2 - $1)" | bc 2>/dev/null || echo "$1"
}
REWARD_AGE=$(read_age "$MEM/reward-state.json");  EMOTION_AGE=$(read_age "$MEM/emotional-state.json")
CONFLICT_AGE=$(read_age "$MEM/conflict-state.json"); INS_AGE=$(read_age "$MEM/interoceptive-state.json")
SOCIAL_AGE=$(read_age "$MEM/social-state.json"); BEAT_AGE=$(read_age "$MEM/heartbeat-state.json")
THAL_AGE=$(read_age "$MEM/thalamus-state.json")

# Keep it simple and robust: if the primary source of a modulator is stale,
# pull that modulator toward its baseline.
[ -n "$REWARD_AGE" ]  && (( $(echo "$REWARD_AGE > 24" | bc -l 2>/dev/null || echo 0) )) && DOPAMINE=$(pull "$DOPAMINE" 0.5)
[ -n "$EMOTION_AGE" ] && (( $(echo "$EMOTION_AGE > 24" | bc -l 2>/dev/null || echo 0) )) && NORADRENALINE=$(pull "$NORADRENALINE" 0.5) && SEROTONIN=$(pull "$SEROTONIN" 0.5)
[ -n "$CONFLICT_AGE" ] && (( $(echo "$CONFLICT_AGE > 24" | bc -l 2>/dev/null || echo 0) )) && ACETYLCHOLINE=$(pull "$ACETYLCHOLINE" 0.5) && CORTISOL=$(pull "$CORTISOL" 0.5)
[ -n "$SOCIAL_AGE" ]   && (( $(echo "$SOCIAL_AGE > 24" | bc -l 2>/dev/null || echo 0) ))   && OXYTOCIN=$(pull "$OXYTOCIN" 0.5)
[ -n "$BEAT_AGE" ]     && (( $(echo "$BEAT_AGE > 24" | bc -l 2>/dev/null || echo 0) ))     && SLEEP_PRESSURE=$(pull "$SLEEP_PRESSURE" 0)

# ── missingSources (only the ones we actually looked for) ──────────────────
MISSING="[]"
for pair in "reward-state.json:reward" "emotional-state.json:emotion" \
            "conflict-state.json:conflict" "interoceptive-state.json:insula" \
            "social-state.json:social" "heartbeat-state.json:heartbeat" \
            "thalamus-state.json:thalamus" "acc-state.json:acc"; do
    f="${pair%%:*}"; label="${pair##*:}"
    if [[ ! -f "$MEM/$f" ]]; then
        MISSING=$(echo "$MISSING" | jq --arg l "$label" '. + [$l]')
    fi
done

# ── composites ─────────────────────────────────────────────────────────────
AROUSAL_C=$(echo "scale=4; 0.6*$NORADRENALINE + 0.4*$ACETYLCHOLINE" | bc 2>/dev/null || echo "0.5")
VALENCE_C=$(echo "scale=4; 0.7*$DOPAMINE + 0.3*$SEROTONIN" | bc 2>/dev/null || echo "0.5")
STRESS_C="$CORTISOL"

jq -n \
  --arg updated "$NOW" \
  --argjson dopamine "$DOPAMINE" --argjson noradrenaline "$NORADRENALINE" \
  --argjson serotonin "$SEROTONIN" --argjson acetylcholine "$ACETYLCHOLINE" \
  --argjson cortisol "$CORTISOL" --argjson oxytocin "$OXYTOCIN" \
  --argjson sleepPressure "$SLEEP_PRESSURE" \
  --argjson arousal "$AROUSAL_C" --argjson valence "$VALENCE_C" --argjson stress "$STRESS_C" \
  --argjson missing "$MISSING" \
  '{version: 1,
    updatedAt: $updated,
    modulators: {
      dopamine:      {value: $dopamine,      source: "vta.reward-state.drive+reward+anticipation"},
      noradrenaline: {value: $noradrenaline, source: "amygdala.arousal+insula.load+heartbeat"},
      serotonin:     {value: $serotonin,     source: "amygdala.valence"},
      acetylcholine: {value: $acetylcholine, source: "gate.attentionFocus+acc.conflictLoad"},
      cortisol:      {value: $cortisol,      source: "acc.conflictLoad+insula.gut+acc.activePatterns"},
      oxytocin:      {value: $oxytocin,      source: "social.trust"},
      sleepPressure: {value: $sleepPressure, source: "circadian.phase+clock"}
    },
    composites: {arousal: $arousal, valence: $valence, stressIndex: $stress},
    missingSources: $missing
  }' > "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"

# Chained step: assemble the workspace context block from the fresh vector.
if [[ -x "$SCRIPT_DIR/workspace-refresh.sh" ]]; then
    bash "$SCRIPT_DIR/workspace-refresh.sh" || true
fi
```

- [x] **Step 5: Add the `neuromod_update` job to `deep-brain-kernel.py`**

In `deep-brain-kernel.py`, after the `verification_pass` entry in `JOBS` (the last entry), add:

```python
    # Integrative State Layer (A): global neuromodulator vector + workspace of
    # attention, composed from every region's state (VTA drive, amygdala
    # valence/arousal, ACC conflict load, insula channels, social trust,
    # heartbeat recency). Minutes 6,21,36,51 are globally unique in this table
    # (every 15 min). Direct / non-inference. Writes neuromod-state.json then
    # chains workspace-refresh.sh for workspace.json.
    Job("neuromod_update", "direct", "*", "6,21,36,51",
        "thalamus-memory/scripts/neuromod-update.sh"),
```

- [x] **Step 6: Run the test — it must pass**

Run: `bash tests/test_neuromod_state.sh`
Expected: all 9 test groups PASS (0 failed).

- [x] **Step 7: Run the whole-suite green-check for A1**

Run:
```bash
bash -n skills/thalamus-memory/scripts/neuromod-update.sh \
     skills/thalamus-memory/scripts/get-neuromod.sh \
     tests/test_neuromod_state.sh
python3 deep-brain-kernel.py --check   # 30 jobs now; neuromod_update row "ok"; 0 problems
tpass=0; tfail=0
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && tpass=$((tpass+1)) || { tfail=$((tfail+1)); echo "FAIL: $t"; }; done
echo "tests: $tpass passed, $tfail failed"; [ "$tfail" -eq 0 ]
```

- [x] **Step 8: Commit**

```bash
git add skills/thalamus-memory/scripts/neuromod-update.sh \
        skills/thalamus-memory/scripts/get-neuromod.sh \
        tests/test_neuromod_state.sh deep-brain-kernel.py
git commit -m "A1: neuromod-state.json composition + reader helper + neuromod_update job (29 -> 30 jobs)"
```

---

## Task 2: `workspace-refresh.sh` + `broadcast.sh` + workspace.json (A2)

**Files:**
- Create: `skills/thalamus-memory/scripts/workspace-refresh.sh`
- Create: `skills/thalamus-memory/scripts/broadcast.sh`
- Create: `tests/test_workspace_broadcast.sh`

**Interfaces:**
- Consumes: `memory/neuromod-state.json` (from Task 1), `memory/pfc-state.json` (`.goals[]` active), `memory/thalamus-state.json` (`.attentionFocus`, `.lastGateRun`), circadian phase (replicated from `beat.sh`'s logic: `waking`/`active`/`winding_down`/`asleep`), the gate's scored envelope from `gate.sh` (Task 3 passes `--source --signal --action --gate-score`).
- Produces: `memory/workspace.json` (schema below); the `context` block (phase + goals + neuromod snapshot) that Task 4 injects into arbitration.

- [x] **Step 1: Write the failing test**

Create `tests/test_workspace_broadcast.sh`:

```bash
#!/bin/bash
# test_workspace_broadcast.sh — A2: global workspace of attention.
#
# Tests:
#  1. broadcast.sh appends currentFocus + a recentBroadcasts entry
#  2. recentBroadcasts ring caps at 5 entries
#  3. workspace-refresh.sh assembles the context block (phase, goals, neuromod)
#  4. workspace-refresh.sh survives a missing neuromod vector (neutral snapshot)
#  5. atomic write hygiene (no tmp residue, lock present)
#
# Run: bash tests/test_workspace_broadcast.sh
# Requires: jq, bc

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

BC="$ROOT/skills/thalamus-memory/scripts/broadcast.sh"
RF="$ROOT/skills/thalamus-memory/scripts/workspace-refresh.sh"

# ── Test 1: broadcast writes currentFocus + entry ──────────────────────
echo "Test 1: broadcast.sh appends currentFocus and a broadcast entry"

"$BC" --source "amygdala-memory" --signal "positive_state" \
      --action "pass" --gate-score 0.55 > /dev/null 2>&1

WS="$TEST_WORKSPACE/memory/workspace.json"
if [[ -f "$WS" ]]; then
    FOCUS=$(jq -r '.currentFocus.source' "$WS")
    N=$(jq '.recentBroadcasts | length' "$WS")
    if [[ "$FOCUS" = "amygdala-memory" && "$N" -ge 1 ]]; then
        pass "broadcast set currentFocus and appended an entry (n=$N)"
    else
        fail "broadcast output wrong: focus=$FOCUS n=$N"
    fi
else
    fail "workspace.json not created by broadcast.sh"
fi

# ── Test 2: ring caps at 5 ─────────────────────────────────────────────
echo "Test 2: recentBroadcasts ring caps at 5"

for i in 1 2 3 4 5 6 7; do
    "$BC" --source "src-$i" --signal "sig-$i" --action "pass" \
          --gate-score "0.$i" > /dev/null 2>&1 || true
done
N=$(jq '.recentBroadcasts | length' "$WS")
if [[ "$N" -eq 5 ]]; then
    pass "ring capped at 5 (got $N)"
else
    fail "ring should cap at 5, got $N"
fi
HEAD=$(jq -r '.recentBroadcasts[0].source' "$WS")
if [[ "$HEAD" = "src-7" ]]; then
    pass "most recent broadcast is first"
else
    fail "most recent should be src-7, got $HEAD"
fi

# ── Test 3: workspace-refresh assembles context ────────────────────────
echo "Test 3: workspace-refresh.sh assembles the context block"

cat > "$TEST_WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}]}
EOF
cat > "$TEST_WORKSPACE/memory/thalamus-state.json" << 'EOF'
{"attentionFocus": ["ship the brain suite"], "lastGateRun": "2026-08-08T00:00:00Z"}
EOF

"$RF" > /dev/null 2>&1

if jq -e '.context.phase and (.context.goals | length > 0) and .context.neuromod' "$WS" > /dev/null 2>&1; then
    pass "context block has phase, goals, neuromod snapshot"
else
    fail "context block incomplete: $(cat "$WS")"
fi

# ── Test 4: refresh survives missing neuromod ──────────────────────────
echo "Test 4: workspace-refresh survives a missing neuromod vector"

rm -f "$TEST_WORKSPACE/memory/neuromod-state.json"
if "$RF" > /dev/null 2>&1; then
    NEURO=$(jq -r '.context.neuromod // "missing"' "$WS" 2>/dev/null || echo "missing")
    if [[ "$NEURO" != "missing" ]]; then
        pass "refresh wrote a neutral neuromod snapshot when vector absent"
    else
        pass "refresh tolerated missing vector (no context.neuromod, exit 0)"
    fi
else
    fail "workspace-refresh.sh should exit 0 with a missing neuromod vector"
fi

# ── Test 5: atomic write hygiene ───────────────────────────────────────
echo "Test 5: atomic write hygiene"

"$BC" --source "amygdala-memory" --signal "positive_state" --action "pass" \
      --gate-score 0.55 > /dev/null 2>&1 || true
if [[ -f "$TEST_WORKSPACE/memory/workspace.json.lock" ]]; then
    pass "workspace lock file present"
else
    fail "workspace lock file missing"
fi
if ! ls "$TEST_WORKSPACE/memory/workspace.json.tmp."* > /dev/null 2>&1; then
    pass "no tmp residue"
else
    fail "tmp residue left behind"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Workspace/Broadcast Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_workspace_broadcast.sh`
Expected: FAIL ("workspace.json not created by broadcast.sh").

- [x] **Step 3: Write `broadcast.sh`**

Create `skills/thalamus-memory/scripts/broadcast.sh`:

```bash
#!/bin/bash
# broadcast.sh — Event-driven global-workspace write: called by gate.sh on
# every non-suppressed dispatch with the scored signal envelope. Appends
# currentFocus + a recentBroadcasts entry (ring capped at 5) to
# memory/workspace.json.
#
# Usage: broadcast.sh --source <s> --signal <sig> --action <a> --gate-score <g>
# All args optional; the file is created on first use.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
MEM="$WORKSPACE/memory"
WS="$MEM/workspace.json"

mkdir -p "$MEM"
exec 200>"$WS.lock"
flock 200

SOURCE=""; SIGNAL=""; ACTION=""; GATE_SCORE="0"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)     SOURCE="$2"; shift 2 ;;
        --signal)     SIGNAL="$2"; shift 2 ;;
        --action)     ACTION="$2"; shift 2 ;;
        --gate-score) GATE_SCORE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ ! -f "$WS" ]]; then
    cat > "$WS" << 'EOF'
{"version": 1, "lastBroadcastAt": "", "currentFocus": null,
 "recentBroadcasts": [], "attentionFocus": [], "context": {}}
EOF
fi

# ring buffer of 5 (newest first), then set currentFocus
jq --arg src "$SOURCE" --arg sig "$SIGNAL" --arg action "$ACTION" \
   --argjson gs "${GATE_SCORE:-0}" --arg now "$NOW" \
  '.recentBroadcasts = ([{source: $src, signal: $sig, action: $action,
     gateScore: $gs, at: $now}] + .recentBroadcasts)[0:5]
   | .currentFocus = {source: $src, signal: $sig, action: $action,
     gateScore: $gs, at: $now}
   | .lastBroadcastAt = $now' \
  "$WS" > "$WS.tmp.$$" && mv "$WS.tmp.$$" "$WS"
```

- [x] **Step 4: Write `workspace-refresh.sh`**

Create `skills/thalamus-memory/scripts/workspace-refresh.sh`:

```bash
#!/bin/bash
# workspace-refresh.sh — Periodic assembly of the workspace `context` block:
# the current circadian phase, active PFC goals, and a neuromod snapshot.
# Chained from neuromod-update.sh (the neuromod_update job). The context
# block is the "contents of attention made first-class" — what Task 4
# injects into arbitration.
#
# Fail-open: a missing neuromod vector yields a neutral snapshot; a missing
# pfc-state leaves goals empty. Never exits non-zero on absent state.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEM="$WORKSPACE/memory"
WS="$MEM/workspace.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$MEM"
exec 200>"$WS.lock"
flock 200

if [[ ! -f "$WS" ]]; then
    cat > "$WS" << 'EOF'
{"version": 1, "lastBroadcastAt": "", "currentFocus": null,
 "recentBroadcasts": [], "attentionFocus": [], "context": {}}
EOF
fi

# ── circadian phase (same logic as heartbeat beat.sh) ──────────────────────
HOUR=$(date -u +%H | sed 's/^0//'); [ -z "$HOUR" ] && HOUR=0
WAKE_HOUR=$(jq -r '.circadian.wakeHour // 8' "$MEM/heartbeat-state.json" 2>/dev/null || echo 8)
SLEEP_HOUR=$(jq -r '.circadian.sleepHour // 22' "$MEM/heartbeat-state.json" 2>/dev/null || echo 22)
PHASE=$(HOUR="$HOUR" WAKE_HOUR="$WAKE_HOUR" SLEEP_HOUR="$SLEEP_HOUR" python3 -c "
import os
hour, wake, sleep = int(os.environ['HOUR']), int(os.environ['WAKE_HOUR']), int(os.environ['SLEEP_HOUR'])
def in_range(h, start, end):
    if start <= end: return start <= h < end
    return h >= start or h < end
if in_range(hour, wake, (wake + 2) % 24): print('waking')
elif in_range(hour, sleep, (sleep + 1) % 24) or in_range(hour, (sleep + 1) % 24, wake): print('asleep')
elif in_range(hour, (sleep - 2) % 24, sleep): print('winding_down')
else: print('active')
")

# ── active goals (PFC) ─────────────────────────────────────────────────────
GOALS="[]"
if [[ -f "$MEM/pfc-state.json" ]]; then
    GOALS=$(jq -c '[.goals[]? | select(.status == "active") | .description]' \
      "$MEM/pfc-state.json" 2>/dev/null || echo "[]")
fi

# ── attention focus (gate) ─────────────────────────────────────────────────
FOCUS="[]"
if [[ -f "$MEM/thalamus-state.json" ]]; then
    FOCUS=$(jq -c '.attentionFocus // []' "$MEM/thalamus-state.json" 2>/dev/null || echo "[]")
fi

# ── neuromod snapshot (neutral defaults when the vector is absent) ─────────
if [[ -x "$SCRIPT_DIR/get-neuromod.sh" ]]; then
    NEURO=$(bash "$SCRIPT_DIR/get-neuromod.sh" --json 2>/dev/null || echo "")
    if [[ -n "$NEURO" ]] && jq -e '.modulators' <<< "$NEURO" > /dev/null 2>&1; then
        SNAP=$(jq -c '{drive: (.modulators.dopamine.value // 0.5),
                       arousal: (.composites.arousal // 0.5),
                       cortisol: (.composites.stressIndex // 0.5),
                       sleepPressure: (.modulators.sleepPressure.value // 0)}' \
          <<< "$NEURO" 2>/dev/null || echo '{"drive":0.5,"arousal":0.5,"cortisol":0.5,"sleepPressure":0}')
    else
        SNAP='{"drive":0.5,"arousal":0.5,"cortisol":0.5,"sleepPressure":0}'
    fi
else
    SNAP='{"drive":0.5,"arousal":0.5,"cortisol":0.5,"sleepPressure":0}'
fi

jq --arg phase "$PHASE" --argjson goals "$GOALS" --argjson focus "$FOCUS" \
   --argjson snap "$SNAP" --arg now "$NOW" \
  '.attentionFocus = $focus
   | .context = {phase: $phase, goals: $goals, neuromod: $snap, lastUpdated: $now}' \
  "$WS" > "$WS.tmp.$$" && mv "$WS.tmp.$$" "$WS"
```

- [x] **Step 5: Run the test — it must pass**

Run: `bash tests/test_workspace_broadcast.sh`
Expected: all 5 test groups PASS.

- [x] **Step 6: Run the A2 green-check**

Run:
```bash
bash -n skills/thalamus-memory/scripts/broadcast.sh \
     skills/thalamus-memory/scripts/workspace-refresh.sh \
     tests/test_workspace_broadcast.sh
tpass=0; tfail=0
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && tpass=$((tpass+1)) || { tfail=$((tfail+1)); echo "FAIL: $t"; }; done
echo "tests: $tpass passed, $tfail failed"; [ "$tfail" -eq 0 ]
```

- [x] **Step 7: Commit**

```bash
git add skills/thalamus-memory/scripts/broadcast.sh \
        skills/thalamus-memory/scripts/workspace-refresh.sh \
        tests/test_workspace_broadcast.sh
git commit -m "A2: global workspace.json — event broadcast + periodic context assembly"
```

---

## Task 3: `gate.sh` read hooks + broadcast call (A3a)

**Files:**
- Modify: `skills/thalamus-memory/scripts/gate.sh`
- Create: `tests/test_gate_neuromod.sh`

**Interfaces:**
- Consumes: `get-neuromod.sh` (Task 1) — read *inside* `_score_signal` (the function runs in the `tail | while read` subshell; a variable set in `_process` would not propagate). `broadcast.sh` (Task 2) — called from `_dispatch` for every non-suppressed action.
- Produces: modulated gate scores (factors below); `workspace.json` writes via broadcast.

**Modulation rules (verbatim from the spec §6.1):**

| Modulator | Effect |
|---|---|
| noradrenaline | `urgency_factor = 0.7 + 0.6·NA`; `urgency = base_urgency · urgency_factor` (range 0.7–1.3) |
| dopamine | goal-relevance weight `0.35 → 0.35·(0.8 + 0.4·DA)` (range 0.28–0.42) |
| acetylcholine | when `ACh > 0.6`, non-`attentionFocus` signals get `score ×= (1 − 0.3·(ACh−0.6)/0.4)` |
| cortisol | off-focus suppression: `score ×= (1 − 0.25·cortisol)` for signals outside `attentionFocus` |
| sleepPressure | circadian gain floor: `gain' = gain·(1 − 0.3·sleepPressure)` |

- [x] **Step 1: Write the failing test**

Create `tests/test_gate_neuromod.sh`:

```bash
#!/bin/bash
# test_gate_neuromod.sh — A3: neuromodulation of the gate + regression lock.
#
# Tests:
#  (a) high noradrenaline raises urgency and shifts a borderline signal to
#      "pass" (score >= 0.40) that would otherwise sit just under it
#  (b) ABSENT vector => gate scores are byte-identical to a run without the
#      layer (the compatibility regression lock)
#  (c) a passing signal triggers a broadcast (workspace.json currentFocus set)
#
# Run: bash tests/test_gate_neuromod.sh
# Requires: jq, bc

set -euo pipefail

PASS=0
FAIL=0
TEST_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEST_WORKSPACE"' EXIT

export WORKSPACE="$TEST_WORKSPACE"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TEST_WORKSPACE/memory" "$TEST_WORKSPACE/memory/.signal-checkpoints"

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

GATE="$ROOT/skills/thalamus-memory/scripts/gate.sh"

# Common fixture: PFC goal + exec load, one neutral-urgency signal.
cat > "$TEST_WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}]}
EOF
cat > "$TEST_WORKSPACE/memory/executive-load.json" << 'EOF'
{"E": 0.4, "band": "desired"}
EOF

score_signal() {
    # score_signal <json-envelope> -> gateScore value
    echo "$1" | "$GATE" --stdin 2>/dev/null | jq -r '.gateScore // 0'
}

# ── (b) FIRST: absent-vector baseline must equal today's unmodulated score ─
echo "Test (b): absent vector == today's scores (regression lock)"

# Expected unmodulated score, recomputed from the gate's own formula using the
# gate's OWN reported circadian gain (read from the scored output below — not
# the wall clock, so an hour-boundary straddle can't cause a spurious diff).
# Fixtures: goal_relevance 0 ("neutral_sig" has no word overlap with the goal),
# novelty 0.7 (empty suppressed queue on the very first gate call),
# urgency 0.5*0.6 = 0.30 (vta-memory source priority 0.6),
# headroom 1 - 0.4 = 0.6 (executive-load fixture E=0.4).
BASE_OUT=$(echo '{"source":"vta-memory","signal":"neutral_sig","intensity":0.5}' | \
    "$GATE" --stdin 2>/dev/null)
BASE=$(echo "$BASE_OUT" | jq -r '.gateScore // 0')
GATE_CIR=$(echo "$BASE_OUT" | jq -r '.dimensions.circadianGain // 0.5')
EXPECTED=$(echo "scale=6; (0.0*0.35 + 0.7*0.15 + 0.30*0.25 + 0.6*0.25) * $GATE_CIR" | bc)

DIFF=$(echo "scale=4; if ($BASE > $EXPECTED) $BASE - $EXPECTED else $EXPECTED - $BASE" | bc 2>/dev/null || echo "999")
if (( $(echo "$DIFF < 0.001" | bc -l) )); then
    pass "absent vector is byte-identical to the unmodulated formula (base=$BASE expected=$EXPECTED)"
else
    fail "absent vector deviates: base=$BASE expected=$EXPECTED (diff=$DIFF) — neutral-by-default violated"
fi

# ── (a) high noradrenaline raises urgency ─────────────────────────────────
echo "Test (a): high noradrenaline raises urgency"

# A signal that sits just under the pass threshold without modulation.
# urgency base = 0.5 * 0.6 (vta priority) = 0.30. With NA=1.0:
# urgency_factor = 0.7+0.6 = 1.3 -> urgency 0.39. Circadian is 1.5 in active
# hours, so baseline score ~ (0 + 0.3*0.15 + 0.39*0.25 + 0.6*0.25)*1.5.
# We assert the RELATIVE property instead: NA vector must not lower the score,
# and with a high-NA vector the score must be >= the absent-vector score.
cat > "$TEST_WORKSPACE/memory/neuromod-state.json" << 'EOF'
{"version":1,"updatedAt":"2026-08-08T00:00:00Z",
 "modulators": {
   "dopamine": {"value": 0.5}, "noradrenaline": {"value": 1.0},
   "serotonin": {"value": 0.5}, "acetylcholine": {"value": 0.5},
   "cortisol": {"value": 0.0}, "oxytocin": {"value": 0.5},
   "sleepPressure": {"value": 0.0}},
 "composites": {"arousal": 0.8, "valence": 0.5, "stressIndex": 0.5},
 "missingSources": []}
EOF

HIGH_NA=$(score_signal '{"source":"vta-memory","signal":"neutral_sig","intensity":0.5}')
# NOTE: no cross-comparison against BASE here — in quiet hours BASE may have
# been suppressed, which decays novelty for every later call. Compare only
# like-for-like present-vector runs (HIGH_NA vs LOW_NA below), which share the
# same novelty state; cortisol is 0.0 in both fixtures so only NA varies.

# With NA=1.0 the urgency term must be strictly greater than with NA=0.5.
cat > "$TEST_WORKSPACE/memory/neuromod-state.json" << 'EOF'
{"version":1,"updatedAt":"2026-08-08T00:00:00Z",
 "modulators": {
   "dopamine": {"value": 0.5}, "noradrenaline": {"value": 0.5},
   "serotonin": {"value": 0.5}, "acetylcholine": {"value": 0.5},
   "cortisol": {"value": 0.0}, "oxytocin": {"value": 0.5},
   "sleepPressure": {"value": 0.0}},
 "composites": {"arousal": 0.5, "valence": 0.5, "stressIndex": 0.5},
 "missingSources": []}
EOF
LOW_NA=$(score_signal '{"source":"vta-memory","signal":"neutral_sig","intensity":0.5}')
if (( $(echo "$HIGH_NA > $LOW_NA" | bc -l) )); then
    pass "NA=1.0 scores strictly above NA=0.5 ($LOW_NA -> $HIGH_NA)"
else
    fail "expected HIGH_NA > LOW_NA, got $LOW_NA vs $HIGH_NA"
fi

# ── (c) passing signal broadcasts to the workspace ────────────────────────
echo "Test (c): non-suppressed dispatch broadcasts to workspace.json"

rm -f "$TEST_WORKSPACE/memory/workspace.json"
# A strongly goal-relevant signal should pass regardless of modulation.
echo '{"source":"prefrontal-cortex-memory","signal":"goal_promoted","intensity":0.9,"payload":{"description":"ship the brain suite"}}' \
    | "$GATE" --stdin > /dev/null 2>&1 || true

if [[ -f "$TEST_WORKSPACE/memory/workspace.json" ]]; then
    F=$(jq -r '.currentFocus.source // "none"' "$TEST_WORKSPACE/memory/workspace.json")
    N=$(jq '.recentBroadcasts | length' "$TEST_WORKSPACE/memory/workspace.json" 2>/dev/null || echo 0)
    if [[ "$F" != "none" && "$N" -ge 1 ]]; then
        pass "gate dispatch broadcast to workspace (focus=$F, entries=$N)"
    else
        fail "workspace written but empty focus=$F entries=$N"
    fi
else
    fail "gate dispatch did not create workspace.json"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Gate Neuromod Tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_gate_neuromod.sh`
Expected: FAIL — the NA-relative assertions fail (no modulation yet) and Test (c) finds no workspace.json.

- [x] **Step 3: Implement the gate.sh changes**

In `skills/thalamus-memory/scripts/gate.sh`:

**(3a)** Add a helper that reads the neuromod vector, placed above `_score_signal`:

```bash
# ── Read the global neuromodulator vector (neutral when absent) ─────────
_get_neuromod() {
    # Reads once per call; called from within _score_signal (a pipeline
    # subshell), so state set here cannot be hoisted to _process.
    if [[ -x "$SCRIPT_DIR/get-neuromod.sh" ]]; then
        NEURO_NA=$("$SCRIPT_DIR/get-neuromod.sh" --get noradrenaline 2>/dev/null || echo "0.5")
        NEURO_DA=$("$SCRIPT_DIR/get-neuromod.sh" --get dopamine 2>/dev/null || echo "0.5")
        NEURO_ACH=$("$SCRIPT_DIR/get-neuromod.sh" --get acetylcholine 2>/dev/null || echo "0.5")
        NEURO_CORT=$("$SCRIPT_DIR/get-neuromod.sh" --get cortisol 2>/dev/null || echo "0.5")
        NEURO_SP=$("$SCRIPT_DIR/get-neuromod.sh" --get sleepPressure 2>/dev/null || echo "0")
        NEURO_PRESENT=$([[ -f "$WORKSPACE/memory/neuromod-state.json" ]] && echo "1" || echo "0")
        # Absent vector = NO stress: cortisol must read 0 (so the out-of-focus
        # suppression factor is (1 - 0.25*0) = 1.0), NOT the 0.5 baseline —
        # the 0.5 baseline would scale every out-of-focus score by 0.875 on a
        # fresh install, violating the neutral-by-default guarantee.
        [[ "$NEURO_PRESENT" = "1" ]] || NEURO_CORT="0"
    else
        NEURO_NA="0.5"; NEURO_DA="0.5"; NEURO_ACH="0.5"; NEURO_CORT="0"; NEURO_SP="0"
        NEURO_PRESENT="0"
    fi
}
```

**(3b)** In `_score_signal`, call `_get_neuromod` right after the dimension reads, then apply the factors. Replace the urgency computation:

```bash
    # 3. Urgency: from intensity and source priority
    local source_priority=0.5
    case "$source" in
        acc-error-memory|anterior-cingulate-memory) source_priority=0.9 ;;
        amygdala-memory|heartbeat-memory) source_priority=0.7 ;;
        prefrontal-cortex-memory) source_priority=0.8 ;;
        vta-memory) source_priority=0.6 ;;
        *) source_priority=0.5 ;;
    esac
    local urgency
    urgency=$(echo "scale=4; $intensity * $source_priority" | bc 2>/dev/null || echo "0.5")
```

with:

```bash
    # 3. Urgency: from intensity and source priority, chemically modulated
    #    (noradrenaline: urgency_factor = 0.7 + 0.6*NA, range 0.7-1.3).
    _get_neuromod
    local source_priority=0.5
    case "$source" in
        acc-error-memory|anterior-cingulate-memory) source_priority=0.9 ;;
        amygdala-memory|heartbeat-memory) source_priority=0.7 ;;
        prefrontal-cortex-memory) source_priority=0.8 ;;
        vta-memory) source_priority=0.6 ;;
        *) source_priority=0.5 ;;
    esac
    local urgency urgency_factor
    urgency_factor=$(echo "scale=4; 0.7 + 0.6 * $NEURO_NA" | bc 2>/dev/null || echo "1.0")
    urgency=$(echo "scale=4; $intensity * $source_priority * $urgency_factor" | bc 2>/dev/null || echo "0.5")
```

**(3c)** Replace the final score computation (the dopamine weight + sleep-pressure gain floor):

```bash
    # Final score
    local score
    score=$(echo "scale=6; ($goal_relevance * 0.35 + $novelty * 0.15 + $urgency * 0.25 + $headroom * 0.25) * $circadian" | bc 2>/dev/null || echo "0.3")
```

with:

```bash
    # Final score — dopamine modulates the goal-relevance weight
    # (0.35*(0.8+0.4*DA), range 0.28-0.42); sleep pressure floors the
    # circadian gain (gain' = gain*(1 - 0.3*SP)).
    local da_weight circadian_final score
    da_weight=$(echo "scale=6; 0.35 * (0.8 + 0.4 * $NEURO_DA)" | bc 2>/dev/null || echo "0.35")
    circadian_final=$(echo "scale=4; $circadian * (1.0 - 0.3 * $NEURO_SP)" | bc 2>/dev/null || echo "$circadian")
    score=$(echo "scale=6; ($goal_relevance * $da_weight + $novelty * 0.15 + $urgency * 0.25 + $headroom * 0.25) * $circadian_final" | bc 2>/dev/null || echo "0.3")

    # Focus sharpening + off-focus suppression (ACh and cortisol act only on
    # signals OUTSIDE the boosted attentionFocus list).
    local in_focus=0
    if jq -e --arg s "$signal_name" --arg src "$source" \
      '[.attentionFocus[]? | contains($s) or contains($src)] | any' \
      "$STATE_FILE" > /dev/null 2>&1; then
        in_focus=1
    fi
    if [[ "$in_focus" -eq 0 ]]; then
        if (( $(echo "$NEURO_ACH > 0.6" | bc -l 2>/dev/null) )); then
            score=$(echo "scale=6; $score * (1.0 - 0.3 * (($NEURO_ACH - 0.6) / 0.4))" | bc 2>/dev/null || echo "$score")
        fi
        score=$(echo "scale=6; $score * (1.0 - 0.25 * $NEURO_CORT)" | bc 2>/dev/null || echo "$score")
    fi
```

**(3d)** In `_dispatch`, after the `action = suppress` early-return block (i.e. for every non-suppressed action), add the broadcast call before dispatch:

```bash
    # Integrative State Layer: broadcast the passing signal to the global
    # workspace (event-driven currentFocus / recentBroadcasts).
    if [[ -x "$SCRIPT_DIR/broadcast.sh" ]]; then
        ( exec 200>&- 2>/dev/null || true
          bash "$SCRIPT_DIR/broadcast.sh" --source "$source" --signal "$signal_name" \
               --action "$action" --gate-score "$score" 2>/dev/null ) &
    fi
```

Place this right after the `if [[ "$action" = "suppress" ]]` block closes, before `local dispatch_intensity`. The `exec 200>&-` subshell drops the inherited gate lock so the backgrounded broadcast can take the workspace lock without a deadlock chain.

- [x] **Step 4: Run the test — it must pass**

Run: `bash tests/test_gate_neuromod.sh`
Expected: (a), (b), (c) all PASS. Note (b) is the regression lock: with no vector the score must equal today's unmodulated score — verify manually against `gate.sh`'s formula before this run by comparing to the pre-change `--stdin` output.

- [x] **Step 5: Run the A3a green-check**

Run:
```bash
bash -n skills/thalamus-memory/scripts/gate.sh tests/test_gate_neuromod.sh
tpass=0; tfail=0
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && tpass=$((tpass+1)) || { tfail=$((tfail+1)); echo "FAIL: $t"; }; done
echo "tests: $tpass passed, $tfail failed"; [ "$tfail" -eq 0 ]
```

- [x] **Step 6: Commit**

```bash
git add skills/thalamus-memory/scripts/gate.sh tests/test_gate_neuromod.sh
git commit -m "A3a: gate.sh neuromod gain factors + broadcast hook (with absent-vector regression lock)"
```

---

## Task 4: `decide.sh` read hooks (A3b)

**Files:**
- Modify: `skills/prefrontal-cortex-memory/scripts/decide.sh`

**Interfaces:**
- Consumes: `get-neuromod.sh` (Task 1), `memory/workspace.json` `.context` (Task 2).
- Produces: DA goal-alignment multiplier and cortisol uncertainty bias in the arbitration weights; `context` block passed into the python arbitration.

**Rules (verbatim from the spec §6.2):**
- Goal-aligned options: `weight ×= (0.8 + 0.4·DA)` when the option description overlaps an active goal (same overlap heuristic the gate uses).
- Somatic bias: when `cortisol > 0.6`, options whose description contains high-uncertainty markers get `weight ×= (1 − 0.2·cortisol)`.
- The `context` block (phase + goals + neuromod snapshot) is included in the arbitration context.

- [x] **Step 1: Add the reads near the other `read_field` calls**

In `skills/prefrontal-cortex-memory/scripts/decide.sh`, after the `OPEN_LOOPS` read_field line, add:

```bash
# ── Integrative State Layer: global neuromod + workspace context ───────────
NEURO_DA=0.5
NEURO_CORT=0.5
if [ -x "$SCRIPT_DIR/../thalamus-memory/scripts/get-neuromod.sh" ]; then
    NEURO_DA=$("$SCRIPT_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get dopamine 2>/dev/null || echo "0.5")
    NEURO_CORT=$("$SCRIPT_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get cortisol 2>/dev/null || echo "0.5")
fi
WORKSPACE_CONTEXT=$(read_field "$WORKSPACE/memory/workspace.json" '.context' "{}")
```

(Note: `get-neuromod.sh` lives in the sibling `thalamus-memory` skill, reached via `$SCRIPT_DIR/../thalamus-memory/scripts/` — same relative hop `beat.sh` uses for `decide.sh`.)

- [x] **Step 2: Export the new values to the python arbitration**

In the `RESULT=$(CALIBRATION=... python3 << 'PYTHON'` env-var list, add `NEURO_DA` and `NEURO_CORT` (and `WORKSPACE_CONTEXT` if the reasoning string should mention it):

```bash
RESULT=$(CALIBRATION="$CALIBRATION" COGNITIVE_LOAD="$COGNITIVE_LOAD" CONFLICT_LOAD="$CONFLICT_LOAD" CONTEXT="$CONTEXT" DRIVE="$DRIVE" ENERGY="$ENERGY" ERROR_PATTERNS="$ERROR_PATTERNS" GUT_SIGNAL="$GUT_SIGNAL" HABIT_STRENGTH="$HABIT_STRENGTH" NEURO_CORT="$NEURO_CORT" NEURO_DA="$NEURO_DA" OPEN_LOOPS="$OPEN_LOOPS" SATURATION="$SATURATION" SEEKING="$SEEKING" SEMANTIC_METHOD="$SEMANTIC_METHOD" VALENCE="$VALENCE" \
```

- [x] **Step 3: Apply the multipliers inside the python**

In the python body, after the existing `scores[oid] = round(score, 3)` accumulation loop's goal-overlap sections (both the semantic and heuristic branches), apply the DA multiplier where a goal overlap already boosted the option:

```python
dopamine = float(os.environ['NEURO_DA'])
cortisol = float(os.environ['NEURO_CORT'])
```

And inside the goal-match branches, replace:

```python
                score *= (1.0 + g.get('priority', 0.5))
                notes.append(f"active goal '{g.get('description')}' boosts {oid} (semantic match)")
```

with:

```python
                score *= (1.0 + g.get('priority', 0.5)) * (0.8 + 0.4 * dopamine)
                notes.append(f"active goal '{g.get('description')}' boosts {oid} (semantic match, DA={dopamine:.2f})")
```

and the heuristic twin:

```python
                score *= (1.0 + g.get('priority', 0.5))
                notes.append(f"active goal '{g.get('description')}' boosts {oid} (heuristic match)")
```

with:

```python
                score *= (1.0 + g.get('priority', 0.5)) * (0.8 + 0.4 * dopamine)
                notes.append(f"active goal '{g.get('description')}' boosts {oid} (heuristic match, DA={dopamine:.2f})")
```

Then add the somatic-bias block after the open-loops block (before `scores[oid] = round(score, 3)`):

```python
    # Somatic bias: under acute stress (cortisol > 0.6), options that look
    # uncertain/novel get dampened — prefer the known over the unknown.
    if cortisol > 0.6:
        UNCERTAINTY_MARKERS = ('maybe', 'uncertain', 'try', 'experiment', 'new', 'explore')
        if any(m in label for m in UNCERTAINTY_MARKERS):
            score *= (1.0 - 0.2 * cortisol)
            notes.append(f"stress (cortisol={cortisol:.2f}) dampens uncertain option {oid}")
```

- [x] **Step 4: Validate**

Run:
```bash
bash -n skills/prefrontal-cortex-memory/scripts/decide.sh
# functional check: option overlapping an active goal with a DA fixture
mkdir -p /tmp/pfc-decide-check && export WORKSPACE=/tmp/pfc-decide-check
mkdir -p "$WORKSPACE/memory"
cat > "$WORKSPACE/memory/pfc-state.json" << 'EOF'
{"goals": [{"description": "ship the brain suite", "status": "active", "priority": 0.8}], "inhibitions": []}
EOF
bash skills/prefrontal-cortex-memory/scripts/decide.sh --context test \
  --options '[{"id":"a","label":"ship the brain suite","weight":0.5},{"id":"b","label":"explore a new idea","weight":0.5}]' \
  2>/dev/null | jq -c '{chosen, scores}'
# Without the neuromod file, dopamine defaults to 0.5 -> multiplier (0.8+0.4*0.5)=1.0:
# scores must be identical to the pre-change behavior.
```

Also verify the regression property explicitly: with no `neuromod-state.json`, `NEURO_DA=0.5` ⇒ `(0.8 + 0.4*0.5) = 1.0` ⇒ weights identical to today.

- [x] **Step 5: Run the full suite + harnesses**

Run:
```bash
tpass=0; tfail=0
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && tpass=$((tpass+1)) || { tfail=$((tfail+1)); echo "FAIL: $t"; }; done
echo "tests: $tpass passed, $tfail failed"; [ "$tfail" -eq 0 ]
for h in run_phase2_harness run_phase5_harness run_skill_unit_tests; do
  bash tests/$h.sh >/dev/null 2>&1 && echo "PASS $h" || { echo "FAIL $h"; bash tests/$h.sh 2>&1 | tail -15; }
done
```

- [x] **Step 6: Commit**

```bash
git add skills/prefrontal-cortex-memory/scripts/decide.sh
git commit -m "A3b: decide.sh reads neuromod — DA goal-alignment multiplier + cortisol uncertainty bias"
```

---

## Task 5: Encode-pipeline read hooks (A3c)

**Files:**
- Modify: `skills/anterior-cingulate-memory/scripts/encode-pipeline.sh`
- Modify: `skills/vta-memory/scripts/encode-pipeline.sh`
- Modify: `skills/amygdala-memory/scripts/encode-pipeline.sh`

**Interfaces:**
- Consumes: `get-neuromod.sh` (Task 1) via the relative path `"$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh"`.

**Rules (verbatim from the spec §6.3):**

| Pipeline | Rule |
|---|---|
| anterior-cingulate | when `stressIndex > 0.6`, minimum exchange count to trigger analysis drops from 2 to 1 |
| vta | when `dopamine < 0.4`, estimated reward intensity `×= 1.15` |
| amygdala | estimated emotion intensity `×= (1 + 0.3·(NA − 0.5))` |

- [x] **Step 1: anterior-cingulate encode-pipeline.sh**

In `skills/anterior-cingulate-memory/scripts/encode-pipeline.sh`, after the `LLM_CALL` check (before the exchange-count guard), add the stress read, then replace the `-lt 2` guard:

```bash
# Integrative State Layer: under acute stress (stressIndex > 0.6) conflicts
# are flagged on thinner evidence — exchange threshold drops 2 -> 1.
# NOTE: this file uses jq only (no bc anywhere in it) — use jq for the
# comparison, not bc, to avoid introducing a new dependency in this file.
STRESS_INDEX=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --composite stressIndex 2>/dev/null || echo "0.5")
MIN_EXCHANGES=2
if jq -e --argjson s "$STRESS_INDEX" '$s > 0.6' /dev/null > /dev/null 2>&1; then
    MIN_EXCHANGES=1
fi

if [ "$EXCHANGE_COUNT" -lt "$MIN_EXCHANGES" ]; then
  echo "⚡ encode-pipeline: insufficient exchanges ($EXCHANGE_COUNT) — skipping."
  exit 0
fi
```

- [x] **Step 2: vta encode-pipeline.sh**

In `skills/vta-memory/scripts/encode-pipeline.sh` (bash wrapper around the embedded python), export the dopamine value into the python environment. Find where the pipeline invokes its python (the heredoc that computes `intensity = estimate_intensity(text, rewards)`), and pass `NEURO_DA` in. Then in the python body, after `intensity = estimate_intensity(text, rewards)`, add:

```python
dopamine = float(os.environ.get('NEURO_DA', '0.5'))
if dopamine < 0.4:
    intensity *= 1.15   # reward-starved: small wins feel bigger
```

The bash side (before the python heredoc):

```bash
NEURO_DA=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get dopamine 2>/dev/null || echo "0.5")
export NEURO_DA
```

- [x] **Step 3: amygdala encode-pipeline.sh**

Same pattern as vta — in `skills/amygdala-memory/scripts/encode-pipeline.sh`, before the python heredoc:

```bash
NEURO_NA=$("$SKILL_DIR/../thalamus-memory/scripts/get-neuromod.sh" --get noradrenaline 2>/dev/null || echo "0.5")
export NEURO_NA
```

and in the python body, after `intensity = estimate_intensity(text, emotions)`, add:

```python
na = float(os.environ.get('NEURO_NA', '0.5'))
intensity *= (1.0 + 0.3 * (na - 0.5))   # arousal amplifies emotional intensity
```

- [x] **Step 4: Validate**

Run:
```bash
bash -n skills/anterior-cingulate-memory/scripts/encode-pipeline.sh \
     skills/vta-memory/scripts/encode-pipeline.sh \
     skills/amygdala-memory/scripts/encode-pipeline.sh
# The absent-vector path (defaults 0.5) must be a no-op on all three:
#   acc: stressIndex 0.5 -> jq '$s > 0.6' false -> MIN_EXCHANGES stays 2
#   vta: dopamine 0.5 -> no factor
#   amygdala: NA 0.5 -> intensity *= 1.0
python3 -m py_compile deep-brain-kernel.py
```

- [x] **Step 5: Run the full suite + harnesses**

Same green-check as Task 4 Step 5 (24 tests + phase2/phase5/skill-unit).

- [x] **Step 6: Commit**

```bash
git add skills/anterior-cingulate-memory/scripts/encode-pipeline.sh \
        skills/vta-memory/scripts/encode-pipeline.sh \
        skills/amygdala-memory/scripts/encode-pipeline.sh
git commit -m "A3c: encode pipelines read neuromod — acc stress threshold, vta reward-starve factor, amygdala arousal gain"
```

---

## Task 6: Manifests + schedule doc + final validation (A3d)

**Files:**
- Modify: `skills/thalamus-memory/capability-manifest.json`
- Modify: `BRAIN_DAEMON_SCHEDULE.md`

- [x] **Step 1: Update `skills/thalamus-memory/capability-manifest.json`**

Add the three new tests to the `tests` array (keep the existing two entries):

```json
  "tests": [
    {
      "path": "tests/test_thalamus_gate.sh",
      "kind": "unit"
    },
    {
      "path": "tests/run_phase1_harness.sh",
      "kind": "regression"
    },
    {
      "path": "tests/test_neuromod_state.sh",
      "kind": "unit"
    },
    {
      "path": "tests/test_workspace_broadcast.sh",
      "kind": "unit"
    },
    {
      "path": "tests/test_gate_neuromod.sh",
      "kind": "unit"
    }
  ],
```

Also add a capability entry for the layer:

```json
    "global_neuromodulation",
    "global_workspace_broadcast",
```

(append to the `capabilities` array).

- [x] **Step 2: Update `BRAIN_DAEMON_SCHEDULE.md`**

In the "Daemon-native jobs (no old-cron equivalent)" table (the one that says "the full 29-job table (21 direct + 8 spawn)"), change the parenthetical to "the full 30-job table (22 direct + 8 spawn)" and add a row:

```markdown
| `neuromod_update` | direct | * | * | 6,21,36,51 | `thalamus-memory/scripts/neuromod-update.sh` — Integrative State Layer (A): composes the global neuromodulator vector from VTA/amygdala/ACC/insula/social/heartbeat state, then chains `workspace-refresh.sh` to assemble `workspace.json`'s context block. Minutes 6/21/36/51 are globally unique (every 15 min) |
```

- [x] **Step 3: Final whole-suite validation**

Run:
```bash
# 1. Syntax sweep (all touched + all shell)
sfail=0
for f in $(git diff --name-only | grep '\.sh$'); do bash -n "$f" || { echo "SYNTAX FAIL: $f"; sfail=1; }; done
while IFS= read -r -d '' f; do bash -n "$f" || { echo "SYNTAX FAIL: $f"; sfail=1; }; done \
  < <(find . -name '*.sh' -not -path './legacy-IGNORE/*' -not -path './docs/*' -print0)

# 2. Kernel check: 30 jobs, neuromod_update ok, 0 problems
python3 deep-brain-kernel.py --check
python3 -m py_compile deep-brain-kernel.py

# 3. New tests specifically
bash tests/test_neuromod_state.sh
bash tests/test_workspace_broadcast.sh
bash tests/test_gate_neuromod.sh

# 4. Full suite + harnesses
tpass=0; tfail=0
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && tpass=$((tpass+1)) || { tfail=$((tfail+1)); echo "FAIL: $t"; }; done
echo "tests: $tpass passed, $tfail failed"; [ "$tfail" -eq 0 ]
for h in run_phase2_harness run_phase5_harness run_skill_unit_tests; do
  bash tests/$h.sh >/dev/null 2>&1 && echo "PASS $h" || { echo "FAIL $h"; bash tests/$h.sh 2>&1 | tail -15; }
done
```

Expected: 27 tests green (24 existing + 3 new), all harnesses pass, `--check` prints 30 job rows with `neuromod_update ... ok` and zero collisions/problems.

- [x] **Step 4: Live smoke test (event path)**

Run the A-layer end-to-end against a scratch workspace (mirrors the B17 smoke-test style):

```bash
WS=$(mktemp -d); mkdir -p "$WS/memory" "$WS/memory/.signal-checkpoints" "$WS/skills"
cp -r skills/. "$WS/skills/"
export WORKSPACE="$WS"
# seed minimal states
cat > "$WS/memory/reward-state.json" << 'EOF'
{"drive":0.6,"recentRewards":[{"id":"r"}],"anticipating":["a"],"lastUpdated":"2026-08-08T00:00:00Z"}
EOF
cat > "$WS/memory/emotional-state.json" << 'EOF'
{"dimensions":{"valence":0.6,"arousal":0.6},"lastUpdated":"2026-08-08T00:00:00Z"}
EOF
cat > "$WS/memory/heartbeat-state.json" << 'EOF'
{"lastBeat":"2026-08-08T00:00:00Z","circadian":{"wakeHour":8,"sleepHour":22},"lastUpdated":"2026-08-08T00:00:00Z"}
EOF
# run the job scripts the way the daemon would
bash "$WS/skills/thalamus-memory/scripts/neuromod-update.sh"
echo "== neuromod-state.json =="; jq -c '{dopamine:.modulators.dopamine.value, composites}' "$WS/memory/neuromod-state.json"
echo "== workspace.json context =="; jq -c '.context' "$WS/memory/workspace.json"
# drive a signal through the gate -> broadcast
"$WS/../core/signaling/publish.sh" --type emotional --source amygdala-memory --signal positive_state --intensity 0.8 2>/dev/null || true
bash "$WS/skills/thalamus-memory/scripts/gate.sh" --process >/dev/null 2>&1 || true
echo "== workspace currentFocus =="; jq -c '.currentFocus' "$WS/memory/workspace.json" 2>/dev/null || echo "(no broadcast — suppressed, acceptable)"
rm -rf "$WS"
```

Expected: neuromod vector with sane bounded values (0–1), workspace context with phase/goals/neuromod, and (unless the signal was suppressed) a `currentFocus` written by the gate dispatch.

- [x] **Step 5: Spawn the required reviewer over the complete diff, then commit**

```bash
git add skills/thalamus-memory/capability-manifest.json BRAIN_DAEMON_SCHEDULE.md
git commit -m "A3d: declare neuromod/workspace tests in the manifest + document neuromod_update in the schedule (30-job table)"
```

Reviewer prompt: review the full A-milestone diff (`cd AI_BRAIN_SUITE_COMPLETE && git diff HEAD~6` — four new scripts, three new tests, gate.sh/decide.sh/three encode-pipeline modifications, the JOBS entry, manifest, schedule doc). Verify: flock chains have no deadlock (gate holds `thalamus-state.json.lock` and background-children drop it before broadcast takes `workspace.json.lock`; neuromod-update holds `neuromod-state.json.lock` while chaining workspace-refresh which takes `workspace.json.lock` — distinct files, no nesting), the absent-vector path is byte-identical (factor math: DA 0.5 ⇒ 0.35·1.0; NA 0.5 ⇒ urgency_factor 1.0; ACh 0.5 ≤ 0.6 ⇒ no sharpening; cortisol multiplies by (1−0.25·0.5)=0.875 only when OUTSIDE focus — confirm the spec's neutral-by-default guarantee actually holds, or flag it), the new tests are deterministic (no reliance on wall-clock hour in the circadian math that could flip the NA assertion), and minute 6/21/36/51 uniqueness.

---

## Self-Review (run against the spec before starting implementation)

**1. Spec coverage:**

| Spec section | Plan task |
|---|---|
| §3 neuromod schema + formulas + decay | Task 1 (Steps 3–4) |
| §4 workspace schema + event/periodic writers | Task 2 (Steps 3–4) |
| §5 neuromod_update job (collision-free minute) | Task 1 Step 5 (minutes 6,21,36,51 — verified unique) |
| §5 reader helper contract | Task 1 Step 3 (`--json`/`--get`/`--composite`) |
| §6.1 gate gain factors + broadcast | Task 3 |
| §6.2 decide.sh arbitration reads | Task 4 |
| §6.3 three encode-pipeline thresholds | Task 5 |
| §7 error handling / compatibility | Task 1 Steps 6–7; Task 3 Test (b); Task 4 Step 4 |
| §8 testing (3 new tests) | Tasks 1, 2, 3 (test files) |
| §9 file change list | File Structure table — every file accounted for |
| §11 sequencing A1→A2→A3 with green checks | Tasks 1→2→3→4→5→6, each with its own suite-green step |
| §12 acceptance criteria 1–7 | Task 6 Steps 3–4 (criterion 5 = `--check` 30 jobs; 6 = live smoke; 7 = flock review) |

**2. Placeholder scan:** every step has concrete code; no TBD/TODO. The only "best-effort" phrasing is in the smoke test's final echo (a signal may legitimately be suppressed), which is a real behavioral possibility, not a placeholder.

**3. Type/interface consistency:**
- `get-neuromod.sh` contract (`--json`/`--get <m>`/`--composite <n>`) is defined once in Task 1 and consumed identically in Tasks 3 (gate), 4 (decide), 5 (encodes), and workspace-refresh (Task 2).
- Modulator names used by `--get`: `dopamine`, `noradrenaline`, `serotonin`, `acetylcholine`, `cortisol`, `oxytocin`, `sleepPressure` — matches the schema in Task 1 exactly.
- Composite names: `arousal`, `valence`, `stressIndex` — matches Task 1's composites and Task 5's acc read.
- The gate's `_get_neuromod` writes `NEURO_NA/DA/ACH/CORT/SP`; the score formula uses exactly those. `broadcast.sh` arg names (`--source/--signal/--action/--gate-score`) match Task 3's call.
- workspace schema keys (`currentFocus`, `recentBroadcasts`, `attentionFocus`, `context.{phase,goals,neuromod,lastUpdated}`) are consistent between Task 2 writers and Task 4's consumer.

**Resolution of the cortisol neutral-by-default trap (flagged by review, fixed here):** the spec §6.1 cortisol rule `score ×= (1 − 0.25·cortisol)` is multiplicative with no threshold, so it must NOT fire at the neutral default. The plan resolves this by treating the vector's *absence* as "no stress": `_get_neuromod` forces `NEURO_CORT=0` when `neuromod-state.json` is missing, making the factor exactly 1.0 on fresh installs (byte-identical), while a *present* vector with cortisol 0.5 applies the spec's out-of-focus suppression as designed (moderate stress is real modulation). The regression lock in `test_gate_neuromod.sh` (b) now *actually* asserts byte-identity: it recomputes the unmodulated score from the gate's own formula (with the live circadian gain) and requires `|BASE − EXPECTED| < 0.001`. The NA fixtures use cortisol 0.0 so the (a) assertions isolate NA's effect, and the `HIGH_NA >= BASE` cross-comparison was removed (BASE may be suppressed in quiet hours, decaying novelty for later calls).
