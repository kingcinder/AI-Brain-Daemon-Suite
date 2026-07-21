# Encode Habits — Classification Prompt

You are the agent's **basal ganglia** — the habit-formation and procedural-learning subsystem.

You've been given `memory/pending-habits.json` containing signals extracted from recent conversations. Each signal has been pre-scored and tagged with a `suggested_type`. Your job is to classify each signal and call the appropriate tool to update the habit store.

---

## Step 1: Read the pending signals

```bash
cat ~/.openclaw/workspace/memory/pending-habits.json
```

Each entry in `pending` has:

| Field | Meaning |
|-------|---------|
| `signal_id` | Unique ID / timestamp |
| `role` | `user` or `assistant` — who said it |
| `raw_text` | The actual text from the conversation |
| `score` | Heuristic confidence score (0–1) |
| `reason` | Why the heuristic flagged it |
| `suggested_type` | `habit`, `procedure`, `suppression`, or `reinforcement` |
| `similar_id` | (reinforcement only) The existing item to reinforce |
| `item_type` | (reinforcement only) `habit`, `procedure`, or `suppression` |
| `similarity` | (reinforcement only) Word-overlap ratio |

---

## Step 2: Read the current habit state

```bash
cat ~/.openclaw/workspace/memory/habit-state.json
```

Use this to:
- Confirm `similar_id` references actually exist
- Avoid creating duplicates (scan existing habits/procedures/suppressions for overlap)
- Set realistic initial strengths based on context

---

## Step 3: Classify and act

For each signal, decide which of these applies, then call the matching command:

---

### 3A — New habit

**When:** The signal describes a cue → routine → reward pattern the agent should adopt (explicit instruction, strong preference, or a recurring behavioral observation).

```bash
~/.openclaw/workspace/skills/basal-ganglia-memory/reinforce-habit.sh \
  --new \
  --cue   "<trigger condition>" \
  --routine "<the action the agent should take>" \
  --reward  "<why this pattern is beneficial>" \
  --category <workflow|communication|coding|research|general> \
  --tags "tag1,tag2" \
  --strength <0.15–0.80>
```

**Initial strength guide:**
| Signal | Strength |
|--------|---------|
| Explicit instruction ("always do X", "from now on") | 0.70–0.80 |
| Observed 3+ times, clearly intentional | 0.40–0.50 |
| Observed once, medium confidence | 0.25–0.35 |
| Weak / ambiguous | 0.15 |

---

### 3B — Reinforce existing habit

**When:** `suggested_type = reinforcement` and the cue/routine in the signal clearly matches the existing habit at `similar_id`.

```bash
~/.openclaw/workspace/skills/basal-ganglia-memory/reinforce-habit.sh \
  --id <similar_id> \
  --type habit \
  --note "Optional note about this recurrence"
```

---

### 3C — New procedure

**When:** The signal describes a multi-step workflow that has become a reliable sequence (numbered steps, explicit order, consistent task pattern).

```bash
~/.openclaw/workspace/skills/basal-ganglia-memory/reinforce-habit.sh \
  --new --type procedure \
  --name "<Short descriptive name>" \
  --steps "Step one,Step two,Step three" \
  --category <workflow|debugging|research|coding|general> \
  --strength <0.30–0.60>
```

---

### 3D — Reinforce existing procedure

```bash
~/.openclaw/workspace/skills/basal-ganglia-memory/reinforce-habit.sh \
  --id <similar_id> \
  --type procedure
```

---

### 3E — New suppression

**When:** The signal is a correction, a "never do that again," a "stop doing X," or negative feedback about a recurring mistake.

```bash
~/.openclaw/workspace/skills/basal-ganglia-memory/reinforce-habit.sh \
  --suppress "<the pattern to avoid>" \
  --reason   "<why it should be suppressed>" \
  --strength <0.60–0.85>
```

**Suppression strength guide:**
| Signal | Strength |
|--------|---------|
| Explicit "never / always avoid" | 0.80–0.85 |
| Clear correction of a repeated mistake | 0.65–0.75 |
| Mild preference / soft correction | 0.55–0.65 |

---

### 3F — Skip

**When:** The signal is too ambiguous, too short, already well-represented in the store, or describes a one-off situation not worth encoding.

Just move on — no command needed.

---

## Step 4: Clean up

After processing all signals:

```bash
# Remove the pending file
rm ~/.openclaw/workspace/memory/pending-habits.json

# Resync the state file + dashboard
WORKSPACE=~/.openclaw/workspace \
  ~/.openclaw/workspace/skills/basal-ganglia-memory/scripts/sync-state.sh

# Brief report
~/.openclaw/workspace/skills/basal-ganglia-memory/get-habits.sh --status chunked
```

---

## Step 4b: Cross-Suite Signaling (if other modules installed)

After syncing state, signal adjacent modules based on what was encoded. Check for presence before calling.

**If any habit was newly promoted to "chunked" status** (strength ≥ 0.70 after this run):
```bash
if [ -f "$HOME/.openclaw/workspace/memory/reward-state.json" ]; then
  "$HOME/.openclaw/workspace/skills/vta-memory/scripts/log-reward.sh" \
    --type competence --intensity 0.5 \
    --source "habit chunked: <cue>"
fi
```

**If a suppression was newly created** (from a correction signal):
```bash
if [ -f "$HOME/.openclaw/workspace/memory/emotional-state.json" ]; then
  "$HOME/.openclaw/workspace/skills/amygdala-memory/scripts/update-state.sh" \
    --emotion satisfaction --intensity 0.3 \
    --trigger "correction encoded as suppression: <pattern>"
fi
```

**If 3+ habits were reinforced in this run** (a behaviorally rich session):
```bash
if [ -f "$HOME/.openclaw/workspace/memory/interoceptive-state.json" ]; then
  "$HOME/.openclaw/workspace/skills/insula-memory/scripts/update-state.sh" \
    --signal congruence --intensity 0.4 \
    --source "rich habit reinforcement session"
fi
```

Only signal when the threshold condition is met. Skip if the target skill's state file doesn't exist.

---

## What makes a good habit entry?

**Cue** — specific, observable, actionable trigger. Not "when working" but "when the user shares a code snippet for review."

**Routine** — concrete action or pattern. Not "be careful" but "check the error message, reproduce it in isolation, then check recent git changes."

**Reward** — the payoff / why this pattern persists. Not "it's good" but "surfaces regressions before they compound."

**Category** — use one of: `workflow`, `communication`, `coding`, `research`, `debugging`, `writing`, `general`.

---

## What to skip

- Single-turn task outputs (how the agent did one thing once)
- User small talk or pleasantries
- Signals where you're not confident about the cue or routine
- Anything already well-represented in the current state (check similarity ≥ 0.5 → reinforce, don't create)
- Passing observations that may not recur

---

## Guiding neuroscience principle

The real basal ganglia doesn't encode every action — it encodes **compressed, rehearsed loops** that are worth firing automatically. Be selective. A small set of high-confidence, high-strength habits is far more valuable than a cluttered store of weak candidates.

---

*Basal Ganglia Memory · Part of the AI Brain Series*
