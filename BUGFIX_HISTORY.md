# Bugfix History — AI Brain Daemon Suite

This file is a security/correctness audit trail for the suite as a whole. It
is **not** the same thing as a per-skill `CHANGELOG.md` (e.g.
`skills/hippocampus-memory/CHANGELOG.md`), which tracks feature history for
that skill alone. This file tracks bug-hunting passes across the *entire*
project — shell-injection classes, logic regressions, data-corruption bugs,
and lint cleanups that span multiple skills.

## Instructions for future bug hunters

If you find and fix a bug in this suite, **please add an entry below**
(newest at the top) so the next person — human or AI — doesn't have to
rediscover what's already been checked, or worse, silently reintroduce
something that was already fixed once. This suite has regressed the same
fixes multiple times across different exported copies; this file exists
specifically to stop that.

---

## 2026-07-20/21 — Full-cycle verification findings (ops + measurement)

### Bug/ops: VRAM gate measured on the wrong GPU
- **Found by:** full local-inference cycle; `nvidia-smi` showed ~33% on Quadro K600 while Quality load was claimed.
- **Root cause:** dual-GPU host — inference is **AMD RX 5700 XT (Vulkan)** via open-gguf; nvidia-smi only sees the display Quadro.
- **Correct measurement:** `/sys/class/drm/card1/device/mem_info_vram_{used,total}` → **~89.7%** with Quality GGUF loaded.
- **Verified:** full_cycle pack `01_vram.txt`; docs in `AGENTS.md` / `V4_STATUS.md`.

### Bug: PSI trigger write EINVAL for unprivileged daemon
- **Found by:** live journal + controlled write to `/proc/pressure/{cpu,memory,io}`.
- **Root cause:** on Ubuntu 6.8 (`CONFIG_PSI=y`), **unprivileged** PSI *trigger registration* returns **EINVAL**; pressure **reads** still work. Root succeeds when payload ends with `\n` or `\0` (bare string without terminator fails even as root).
- **Fix:** `deep-brain-kernel.py` `PSIMonitor` falls back to **avg10 poll mode** when trigger write fails (not silent no-op).
- **Verified:** journal poll-fallback lines; `docs/verification/full_cycle_20260720T234945Z/psi_fresh_diagnosis.txt` + `psi_trigger_format_probe.txt`.

### Bug: evaluate latency false positive (earlier same day)
- **Found by:** e2e pipeline reject with `latency_increase` ~5× while regression was green.
- **Root cause:** baseline stored unitless `latency_norm: 1.0` treated as 1.0 **seconds**.
- **Fix:** measure/store real `latency_sec`; re-enable `latency_checked` with measured baseline.
- **Verified:** evaluate JSON `latency_checked:true`, latency_sec ≈ 6.15s on full cycle.

### Ops: live daemon jobs failing on missing skill state
- **Found by:** journalctl on `aibrain.service` during full cycle (`heartbeat_beat`, `insula_encoding`).
- **Root cause:** workspace never had initial state files (`heartbeat-state.json`, insula install, etc.); lock files alone are not enough.
- **Fix:** run each skill’s `install.sh` (no cron required) to create default state; retest beat/encode + full skill unit suite.
- **Verified:** retests in full_cycle pack; skill units 11/0 after install.

### Non-bug note: fast local generate (~3s) after warm KV
- Prompt reuse yields high `cached_tokens` / LCP hit; still a real `chat/completions` call (completion tokens + llama-server timings). Do not treat wall-clock alone as “stub proposal.”


For each entry, show your work. At minimum include:

1. **What tool/method found it.** Name the actual command (`shellcheck -S
   style ...`, `bash -n`, manual read, live execution with a crafted
   payload, etc.). "I noticed" is fine for manual review, but say what you
   were looking at.
2. **Root cause, not just symptom.** If the fix is "add quotes," say *why*
   the unquoted form was wrong (word-splitting? glob expansion? shell
   injection into an embedded interpreter?). If you patched a false-positive
   lint warning, explain the actual mechanism that confused the linter and
   why your fix addresses that mechanism rather than just suppressing the
   warning.
3. **Every file touched**, not just the first one you found. Several bugs in
   this suite's history existed identically across 3–11 duplicated copies of
   the same script (e.g. `dashboard-builder.sh` is intentionally identical
   across every `skills/*/scripts/` directory). Grep for the same pattern
   suite-wide before declaring a fix complete.
4. **How you verified the fix**, concretely — not just "tested it." Prefer:
   - `bash -n` on every changed file
   - `shellcheck` at `-S style` (the strictest level) across the whole tree,
     not just the file you touched
   - For anything touching an embedded `python3 -c` / heredoc block: parse
     the extracted Python with `ast.parse` to confirm it's still valid
   - For injection-class bugs specifically: **live-test with an adversarial
     payload** (an apostrophe, a `"; import os; os.system(...)`, etc.) and
     show the output proves the payload was treated as inert data, not
     executed or used to corrupt state.
5. **What you deliberately did NOT change**, if anything, and why. E.g. a
   lint warning that's a true false-positive, or a fix you judged too risky
   for the value it added. Future hunters shouldn't have to re-litigate a
   decision you already made carefully — but they also shouldn't trust that
   claim blindly, so give them enough to check it themselves.

Suggested entry template:

```
## [Round N] — YYYY-MM-DD

### Found via
<tool/command/method>

### Bug: <short name>
- **Root cause:** <mechanism, not just symptom>
- **Files:** <every file touched, or "N identical copies across
  skills/*/scripts/<name>.sh">
- **Fix:** <what changed and why this addresses the root cause>
- **Verified:** <specific commands run + what they showed>

### Deliberately left alone
- <thing> — <why, and what would make it worth revisiting>
```

---

## [Round 8] — 2026-07-11

### Found via
This entry covers a full arc of work across a single long-running session,
not one grep pass — so methods varied by finding: live execution against
bare/synthetic workspaces (the primary method), an isolated `asyncio.Lock`
repro before touching the real code, direct reads of the actual daemon job
table cross-checked against the shipped skill tree, and — for this specific
round-7 reconciliation — a file-by-file diff of *my own* prior fixes against
this uploaded copy, since this suite has regressed already-fixed bugs
before (see this file's own stated purpose). I did not run shellcheck or
adversarial injection payloads in this round; that's Round 1–6/7's territory
and I didn't reproduce it. Treat shell-injection-class coverage as
Round 1–7's claim, not mine.

### Bug: ACC's `encode-pipeline.sh` called the paid Anthropic cloud API directly, unlike every other skill
- **Root cause:** design inconsistency, not a crash bug. Every other
  LLM-backed skill (PFC's `semantic-match.sh` is the reference pattern)
  calls a local OpenAI-compatible server via a shared `llm-call.sh`
  utility — local-only, zero marginal cost, no API key. ACC's
  `encode-pipeline.sh` instead called `api.anthropic.com` directly via raw
  `urllib`, requiring `ANTHROPIC_API_KEY`, with no equivalent fallback
  story if that key was absent mid-fleet.
- **Files:** `skills/anterior-cingulate-memory/scripts/encode-pipeline.sh`
  (full rewrite), plus `llm-call.sh` and `safe-write.sh` newly bundled into
  that same `scripts/` folder (copied from PFC's copies, matching the
  suite's existing per-skill-bundles-its-own-copy convention rather than
  inventing a new shared-path convention).
- **Fix:** rewrote to build the user/system prompt via `jq -n` (not Python
  triple-quoted string interpolation — avoids transcript content with
  quotes/backslashes breaking out of a Python string literal), call the
  local server through `llm-call.sh`, strictly validate the JSON response
  shape (drop malformed conflict/flag entries rather than trust them
  wholesale), and write state through `safe-write.sh`'s lock-guarded
  pattern instead of an unguarded read-mutate-write.
- **Verified:** built a full test harness with the real unmodified
  `preprocess-exchanges.sh`/`log-conflict.sh`/`flag-attention.sh` and a
  mock local LLM server. Caught and fixed two real bugs *during* that
  testing, not after: (1) `\(load)` vs `\($load)` in the jq template — jq
  has a builtin `load/0`, so the unprefixed form silently tried to call it
  instead of reading the bound variable; (2) the exact `set -e` +
  `VAR=$(cmd); STATUS=$?` footgun this file's own history keeps
  rediscovering — `RAW_OUTPUT=$(...); LLM_STATUS=$?` would have killed the
  whole script the instant the local server failed, before the status was
  ever read, silently defeating the fail-open contract it was supposed to
  have. Fixed via `if RESULT=$(...); then ... else ...; fi`. Re-verified
  after fixing both: success path (conflict+flag logged, state updated
  under lock), local-server-down path (exit 0, state untouched, warning
  logged), malformed-JSON path, and markdown-fenced-JSON path (some local
  servers wrap JSON output in ```` ```json ```` even in JSON mode) — all four
  confirmed via direct execution, not inspection.

### Gap: no pressure-awareness in the original bash scheduling daemon
- **Root cause:** a separate PSI-based prototype kernel
  (`deep-brain-kernel.py`'s eventual bash-era predecessor, `brain-kernel.py`)
  existed with real `/proc/pressure` monitoring but an empty scheduler loop
  (literally `# Placeholder for task execution logic`) — never reconciled
  with the actual production `brain-daemon.sh`, which had a real 18-job
  table but zero system-load awareness and would fire jobs straight into
  heavy local Vulkan-inference load.
- **Files:** `legacy/brain-daemon.sh` (now superseded as the active engine
  by `deep-brain-kernel.py`, but ported here since it was still the active
  engine at the time and is kept as a rollback option).
- **Fix:** ported `get_psi_avg10`/`is_system_saturated` (avg10 threshold
  read from `/proc/pressure/{memory,cpu}`, default threshold 10.0,
  overridable via `BACKPRESSURE_THRESHOLD` env) into the daemon's tick
  loop. `spawn`-type jobs defer under saturation (without marking
  themselves fired, so they retry next tick if pressure clears within the
  same matching minute); `direct` jobs run regardless, since they're cheap
  local math/rule-based encoders, not LLM calls. Edge-triggered logging
  (one warning on entering saturation, one info line on exit), not a log
  line every tick. Fails open if `/proc/pressure/*` isn't readable.
- **Verified:** synthetic PSI files with a crafted `avg10=15.32` line
  confirmed correct threshold parsing and OR-across-both-metrics logic via
  `--check`'s new PSI-reporting output.

### Gap: two parallel daemon implementations, one bash + no GPU awareness, one Python + unverified against real skills
- **Root cause:** not a bug — a reconciliation task. A second uploaded
  package (`deep-brain-kernel-suite.zip`) contained a from-scratch async
  Python rewrite of the scheduler (epoll-driven PSI, `pidfd`-based process
  tracking, cgroups v2 throttling, GPU VRAM checking via
  `nvidia-smi`/`rocm-smi`) explicitly written as `brain-daemon.sh`'s
  replacement, but its job table had never been validated against an
  actual skill-script tree, and its author's own header honestly flagged
  PSI-epoll-trigger registration, cgroup delegation, and GPU-tool parsing
  as *built but not exercised* against real kernel/systemd/GPU state.
- **Files:** none changed — this was verification, not a fix.
- **Verified:** ran the shipped `--check` against the real fixed skill
  tree: all 18 jobs' script paths resolved, zero minute collisions. Ran
  the daemon live for several seconds in a sandbox with no PSI, no cgroup
  delegation, no GPU — confirmed it degrades to warnings, not crashes, on
  all three. Adopted `deep-brain-kernel.py` as the canonical engine on
  this basis; archived `brain-daemon.sh` under `legacy/` as a working,
  already-PSI-patched rollback rather than deleting it.

### Bug: unbounded spawn-lock starvation in `deep-brain-kernel.py`
- **Root cause:** `run_spawn()` awaited `proc.communicate()` with no
  timeout while holding `_spawn_lock` (the "one real agent-turn at a time"
  lock shared by all 6 spawn-type jobs). One hung `sessions:spawn` call —
  network stall, a model stuck generating, an agent turn that never
  returns — would silently starve every other spawn-type job forever, with
  nothing logged, until a manual daemon restart. `run_direct()` had the
  same missing-timeout gap, lower stakes since direct jobs aren't
  serialized behind a shared lock.
- **Files:** `deep-brain-kernel.py` (`run_direct`, `run_spawn`, new
  `_await_with_timeout()` helper, `circadian_scheduler`/`dispatch`/
  `run_daemon`/`main` all threaded to pass timeout params through).
- **Fix:** `_await_with_timeout()` wraps `proc.communicate()` in
  `asyncio.wait_for()`; on timeout, kills the process via its pidfd
  (race-free, same mechanism as normal shutdown), gives it 5s to actually
  exit, returns `(b"", True)` rather than raising. New `--direct-timeout`
  (default 300s) / `--spawn-timeout` (default 900s — real agent turns
  legitimately run longer than scripts) flags.
- **Verified:** isolated `asyncio.Lock` repro first, confirming the bug
  shape in the abstract. Then a repro against the **real**
  `_spawn_lock`/`_await_with_timeout` with a genuinely hung `sleep 999`
  subprocess: two queued waiters that would previously have blocked
  forever both unblocked at exactly the 2s configured timeout. Confirmed
  the killed process didn't linger as a zombie. Re-ran `--check` after —
  still clean. (Also caught and fixed my own slip mid-edit here: a
  `str_replace` dropped the module docstring's closing `"""`; caught via
  `py_compile` before it reached any shipped copy.)

### Bug: 3 scripts in `acc-error-memory` crashed with raw Python tracebacks instead of failing gracefully
- **Root cause:** unlike every sibling script in the same skill (which
  check `[ -f "$STATE_FILE" ]` or wrap the read in `try/except` before
  touching it), three scripts had an unguarded `with open(state_file)`
  inside an embedded `python3` heredoc. Found via a suite-wide automated
  sweep (parse every `python3 <<` heredoc block in every skill script,
  flag reads with no guard in the preceding ~6 lines, then manually
  re-verify each candidate's *actual* bash-level context since the
  heuristic had both false positives — guards further back than the
  window checked — and one real false negative, a heredoc invocation
  prefixed with inline env-var assignments `VAR=... python3 << 'PYTHON'`
  that the first regex pass anchored to line-start missed entirely).
- **Files:** `skills/acc-error-memory/scripts/resolve-check.sh` (line 19),
  `get-lessons.sh` (line 38), `log-error.sh` (line 43).
- **Fix:** `resolve-check.sh`/`get-lessons.sh` — added the same
  `[ ! -f "$STATE_FILE" ]` bash guard the skill's own `sync-state.sh`
  already used as local precedent, printing a clean message and exiting 0
  ("nothing to do yet" is a correct response for these two). `log-error.sh`
  is different: its whole job is to record a *new* error, so silently
  doing nothing on missing state would drop a real report. Instead it now
  self-initializes `acc-state.json` with the exact schema `install.sh`
  itself uses, under the same `flock` already held, then proceeds.
- **Verified:** all three re-executed against a genuinely bare workspace
  (`rm -rf` fresh, not just missing one file) — no tracebacks, correct
  exit codes, and for `log-error.sh` specifically, confirmed the
  self-initialized file round-trips correctly (`jq` on the result shows
  the new pattern actually landed).
- **Regression note (this round, this upload specifically):** on
  re-verifying against this Round 7 upload before touching anything, found
  `log-error.sh`'s self-init guard had reverted to the original unguarded
  form — `resolve-check.sh`/`get-lessons.sh`'s guards survived intact, this
  one specifically didn't, most likely lost in a manual merge somewhere
  between when it was first fixed and this export. Reapplied verbatim and
  re-verified per above. Flagging the mechanism, not just the symptom: this
  file's own stated purpose is to stop silent regressions like this one —
  worth someone checking why a partial revert happened here specifically
  when the other two survived.

### Gap: two competing dashboard-generation mechanisms racing on the same output file
- **Root cause:** 7 skills had a monolithic `generate-dashboard.sh`
  (~600 lines) that read every sibling skill's state directly and
  overwrote `$WORKSPACE/brain-dashboard.html` wholesale. 4 skills had a
  newer, smaller fragment-writer pattern (`generate-dashboard.sh` writes
  only `dashboard-fragments/<id>.json` for its own skill, then calls a
  shared `dashboard-builder.sh`) — but `dashboard-builder.sh`'s registry
  covered all 11 skills, and for any registry entry with no fragment file
  it rendered a **"not installed, run `clawdhub install <slug>`"** card.
  Since the 7 monolithic skills never wrote a fragment, the fragment path
  made 7 real, working, installed skills falsely appear uninstalled
  whenever it ran — and both mechanisms wrote the identical filename, so
  whichever ran most recently fully determined the page. Confirmed live
  (not theoretical): `hippocampus`/`insula`/`vta`'s own `install.sh` each
  auto-triggered the monolithic path at install time.
- **Files (my fix, applied to the 4 skills that had `dashboard-builder.sh`
  at the time):** `skills/{prefrontal-cortex,cerebellum,social,
  heartbeat}-memory/scripts/dashboard-builder.sh` (all 4, byte-identical).
- **Fix (mine, at the time):** repointed the fragment path's default
  `OUTPUT_FILE` to a separate `brain-dashboard-fragments.html` instead of
  the shared filename (eliminates the destructive race entirely — trades
  it for two dashboard files existing until a full migration), and
  replaced the "not installed" message with an accurate "hasn't migrated
  to the fragment format yet — this does NOT mean it's uninstalled or
  broken" message for the interim.
- **Verified (mine):** simulated a real monolithic dashboard's content,
  ran the fragment builder against the same workspace, confirmed the
  monolithic file was left untouched and the builder wrote its own
  separate file instead; confirmed the corrected message text renders for
  every non-fragment registry entry.
- **Superseded, not present in this upload — and correctly so:** this
  round's re-verification found `dashboard-builder.sh` is now
  byte-identical across **all 11** skills (was 4), and every
  `generate-dashboard.sh` is now the short fragment-writer form (53–80
  lines; the old ~600-line monolithic version is gone suite-wide).
  Whoever did this completed the real fix — the actual migration — that my
  patch above was explicitly a stopgap for. `OUTPUT_FILE` correctly points
  back at the shared `brain-dashboard.html` in this upload, which is now
  *correct* rather than the reintroduced original bug, since there's no
  longer a competing monolithic writer for it to race against. Confirmed
  by checking `hippocampus`'s new `generate-dashboard.sh` actually builds
  a fragment (not a full page) and that `install.sh`'s call sites are
  unchanged text but now invoke the new fragment-writing script. No action
  taken here — deliberately left as-is, since re-applying my old
  file-splitting patch on top of the real fix would undo a better solution.

### Deliberately left alone
- Round 1–7's shellcheck/injection-hardening and `deep-brain-kernel.py`
  feature work (weekly consolidation jobs, the `due_now()` date-key bug,
  `--status`/job-health tracking, `--enable-yolo` audit trail, point-in-time
  PSI check before spawn commit). Not reproduced or independently
  reverified in this round — flagging that explicitly per this file's own
  Round 7 entry, which already flagged the same about Rounds 1–6. If this
  chain of "did not reverify the layer below me" continues, at some point
  someone needs to do a from-scratch adversarial pass across the whole
  tree rather than each round trusting the previous one's word.
- The dashboard fix's supersession, noted above rather than silently
  dropped, specifically so nobody re-applies the now-obsolete stopgap on
  top of the real migration in some future round.

---

## [Round 7] — 2026-07-11

### Found via
A requested critique of the whole suite against its own stated purpose
(staged AGI architecture, Stage 1), scored across correctness, honesty of
docs, and verification depth — followed by targeted fixes for each finding
across several follow-up turns. This round did not touch shell scripts or
run shellcheck; it's scoped to `deep-brain-kernel.py`, its job table, and
top-level/skill docs. **Note on the Round 1–6 entries below:** those were
not authored or independently reverified by me in this pass — I did not run
shellcheck or the adversarial payload tests they describe. This entry only
covers what I actually did.

### Gap: no proof PFC's arbitration (`decide.sh`) actually changes behavior
- **Root cause:** n/a — a verification gap, not a code bug. `decide.sh`
  reads and scores sibling state but nothing in the suite demonstrated
  end-to-end that scores actually move in response to that state.
- **Files:** `tests/pfc_decide_harness.sh` (new).
- **Fix:** closed-loop harness — synthetic `pfc-state.json` + sibling state
  files (interoceptive/conflict/acc/emotional/social),
  `PFC_SEMANTIC_MATCHING=off` for determinism, 7 pass/fail assertions run
  against the real `decide.sh`, not a mock.
- **Verified:** `bash tests/pfc_decide_harness.sh` — all 7 assertions pass
  against the shipped script. Re-ran against this Round 6 upload
  specifically (not just my own working copy): still 7/7, `deep-brain-kernel.py`
  still compiles clean.

### Gap: weekly self-reflection/consolidation never scheduled
- **Root cause:** `hippocampus-memory/scripts/consolidate.sh` and
  `reflect.sh` (plus their prompt files) were written for weekly use — the
  skill's own docs describe them that way — but never had a cron/daemon
  entry in either the legacy bash daemon or `deep-brain-kernel.py`. Manual-
  invocation-only in every version of this suite.
- **Files:** `deep-brain-kernel.py` (`Job.days` field, JOBS table),
  `BRAIN_DAEMON_SCHEDULE.md`.
- **Fix:** added `hippocampus_weekly_consolidation` and
  `hippocampus_weekly_reflection` as Sunday-only spawn jobs (`days="6"`,
  `datetime.weekday()` convention: 0=Mon..6=Sun), 02:34/02:44 UTC —
  deliberately outside the regular 3-hourly cadence so they don't compete
  for the spawn lock.
- **Verified:** `--check` shows both jobs, zero minute collisions against
  the other 18; direct scenario test confirms Sunday-only gating and
  correct weekly recurrence.

### Bug: `due_now()`'s dedupe key had no date — every job fires once, ever
- **Root cause:** `last_fired_key` was `"H:M"` only and never reset. The
  day after a job first fired, the next occurrence of that same `"H:M"`
  matched the value already stored, so `due_now()` returned `False`
  permanently from then on. **Every job in the table was exposed to this,
  not just the new weekly ones** — found while wiring in the jobs above,
  since a weekly job is the worst-case exposure (a week's gap makes it
  impossible to miss). Inherited unchanged from `legacy/brain-daemon.sh`'s
  `LAST_FIRED_KEY` (same date-less key there; not patched, since legacy is
  rollback-only, not active).
- **Files:** `deep-brain-kernel.py` (`_job_key()`, `due_now()`, both call
  sites in `circadian_scheduler`).
- **Fix:** key now includes the date (`YYYY-MM-DD:H:M`).
- **Verified:** direct scenario test against concrete dates — same-minute
  re-poll (simulating the 30s tick landing twice in one matching minute)
  still correctly suppressed; next-day recurrence now fires (previously
  did not, confirmed both before and after the fix); weekly job recurs
  correctly the following Sunday.

### Gap: no per-job failure-history visibility
- **Root cause:** `DaemonState` tracked only each job's last-fired minute,
  nothing about whether it actually succeeded. A job silently broken since
  day one (missing script, `hermes` gone, a parsing exception) looked
  identical in the state file to a healthy one.
- **Files:** `deep-brain-kernel.py` (`DaemonState.job_stats`,
  `record_result()`, `print_status()`, new `--status` flag), `README.md`.
- **Fix:** persistent per-job success/failure/consecutive-failure-streak
  tracking. Deferrals (VRAM limit, PSI pressure, missing `hermes`, missing
  script) deliberately do NOT count as failures — those are the scheduler
  correctly declining to run. New `--status` command prints a per-job
  table, flags 3+ consecutive failures as `⚠ UNHEALTHY`, exits with the
  unhealthy count for use as a monitoring check.
- **Verified:** synthetic state file with one healthy job (40 success/0
  failure) and one broken job (2/4, streak 4) — `--status` correctly
  flagged only the broken one, exit code 1; a clean state file gave exit 0.

### Gap: unattended spawn jobs always ran with `--yolo --accept-hooks`, no audit trail
- **Root cause:** not a code bug — a privilege default inconsistent with
  the rest of the file's own privilege reasoning (see its eBPF/CAP_BPF
  discussion). Cron-equivalent, unattended agent turns were auto-approving
  every tool/hook call with no opt-in and no record of what ran.
- **Files:** `deep-brain-kernel.py` (`--enable-yolo` flag, `_audit_spawn()`).
- **Fix:** `--yolo`/`--accept-hooks` now require explicit `--enable-yolo`
  (off by default — spawn jobs still run, just without auto-approval).
  Every spawn dispatch, yolo or not, is appended to
  `WORKSPACE/memory/aibrain-spawn-audit.jsonl` (job name, timestamp, task
  text, yolo flag).
- **Verified:** manually constructed both command variants (yolo and
  no-yolo) to confirm correct flag placement in the `hermes chat` argv;
  confirmed `_audit_spawn()` is called on every path through `run_spawn()`
  before the lock is taken, not just the yolo path.

### Gap: two ACC skills with no documented boundary
- **Root cause:** not a code bug — a documentation gap.
  `anterior-cingulate-memory` (conflict/uncertainty, real-time) and
  `acc-error-memory` (confirmed mistakes, post-correction) both map to the
  same brain region and looked redundant, with no more than a one-line
  self-reference inside each skill's own `SKILL.md` and no worked
  decision rule anywhere.
- **Files:** `README.md` (new "Why are there two ACC skills?" section),
  `skills/anterior-cingulate-memory/README.md`,
  `skills/acc-error-memory/README.md` (new reciprocal "Complement to..."
  sections — previously only `anterior-cingulate-memory`'s README gestured
  at the split at all).
- **Fix:** explicit routing rule in all three docs: pre-action uncertainty
  → `anterior-cingulate-memory`; post-correction confirmed mistake →
  `acc-error-memory`. Also documents that the same underlying issue
  appearing in both isn't duplicate logging — it's predicted-vs-materialized
  calibration signal.
- **Verified:** manual read-through of all three sections for internal
  consistency; no code path affected, doc-only change.

### Bug: spawn jobs deferred only via the delayed PSI trigger, not point-in-time pressure
- **Root cause:** `PSIMonitor`'s epoll trigger only reports pressure after
  the kernel's stall-threshold has already crossed, by design (that's what
  makes it interrupt-driven). A spawn job evaluated in the gap between
  "pressure is rising" and "the trigger actually fires" could still launch
  straight into it.
- **Files:** `deep-brain-kernel.py` (`psi_avg10()`, `run_spawn()`).
- **Fix:** added a synchronous, instantaneous read of
  `/proc/pressure/{memory,cpu}` immediately before a spawn job commits to
  firing, independent of whether the trigger has crossed yet.
- **Verified:** unit-tested the `avg10=` line-parsing logic against a
  realistic `/proc/pressure` sample line (correctly extracts `12.34` from
  a synthetic `some avg10=12.34 ...` line); confirmed `--check` and the
  full daemon startup path are unaffected by the new parameter threading
  through `dispatch`/`circadian_scheduler`/`run_daemon`/`main`.

### Deliberately left alone
- The Round 1–6 shellcheck/injection-hardening work below this entry. Not
  reproduced, not re-run, not vouched for by me — if that work needs
  re-confirming as part of a future audit, treat it as a separate pass.

---

## [Round 6] — 2026-07-11

### Found via
Independent reverification of `decide.sh` (requested by user against a
separate two-candidate diff, resolved in an earlier session — see that
session's hybrid for full reasoning), then a targeted suite-wide grep for
the specific *variant* of the injection class this file's history flags as
easy to miss: `grep -rn "python3 << [A-Z]" --include='*.sh' . | grep -v "<< '"`
— i.e. heredocs whose delimiter is unquoted, which the Round 1–2 entry
explicitly warned "a single grep pattern... will miss" if you only search
for the `python3 -c "..."` form.

### Bug: `decide.sh` — reverified, not regressed
- **Root cause:** n/a — this round found the Round 5 fix (env-var +
  single-quoted heredoc) already correctly in place. No code change made.
- **Files:** `skills/prefrontal-cortex-memory/scripts/decide.sh`
- **Fix:** none needed.
- **Verified:** `bash -n` clean; extracted heredoc parses via `ast.parse`;
  live adversarial test with
  `--context "user's request; import os; print('PWNED')"` against a real
  `pfc-state.json` — the full payload round-tripped intact inside the
  JSON `context` field (both stdout and the persisted `decisionLog` entry),
  no execution, no crash. Logged here per this file's own instructions so
  a future export doesn't need to re-derive that this file is clean.

### Bug: unquoted heredoc delimiters — the exact regression class the Round 1–2 entry predicted, found in 5 files
- **Root cause:** `python3 << PYTHON` (no quotes around the delimiter)
  makes bash perform its normal variable/command substitution on the
  heredoc body before Python ever sees it — identical mechanism to the
  `python3 -c "..."` injection class, just a different-looking source
  pattern. All five instances embedded a shell variable directly as a
  Python literal (`VAR = "$SHELL_VAR"` or bare `VAR = $SHELL_VAR` for
  numerics) inside the unquoted heredoc body.
- **Files, in order of severity:**
  1. `skills/acc-error-memory/scripts/update-watermark.sh` — **directly
     exploitable**: `$TIMESTAMP` is populated straight from a user-supplied
     `--timestamp` CLI flag with zero validation before hitting the
     heredoc. This is the same shape as the original `decide.sh
     --context` vulnerability that started Round 1.
  2. `skills/hippocampus-memory/scripts/load-core.sh` — `$INDEX`/`$THRESHOLD`
     sourced from `$WORKSPACE` and the `THRESHOLD` env var; lower severity
     (not raw free-text CLI input) but same mechanism, and a `$WORKSPACE`
     path containing a quote or backslash would already have broken this
     before any adversarial intent.
  3. `skills/hippocampus-memory/scripts/sync-core.sh` — same shape as
     load-core.sh (`$INDEX`, `$OUTPUT`, `$THRESHOLD`).
  4. `skills/basal-ganglia-memory/scripts/sync-state.sh` — `$STATE_FILE`,
     `$OUTPUT`, `$CHUNK_THRESHOLD`, `$ACTIVE_THRESHOLD`, all env/workspace-
     derived.
  5. `skills/basal-ganglia-memory/scripts/decay-habits.sh` — `$STATE_FILE`
     only.
- **Fix:** for each file, changed `python3 << PYTHON` to `python3 <<
  'PYTHON'` (single-quoted delimiter — bash performs zero expansion inside)
  and moved every previously-spliced variable to an `os.environ[...]` read,
  passed in via `VAR="$var" python3 << 'PYTHON'` on the line immediately
  above the heredoc, exactly matching the pattern already established in
  `decide.sh`, `amygdala-memory/scripts/*`, and the rest of the suite.
  Numeric values (`THRESHOLD`, `CHUNK_THRESHOLD`, `ACTIVE_THRESHOLD`) are
  now explicitly `float(os.environ[...])` inside Python rather than relying
  on bash to paste a bare numeric literal into Python source.
- **Verified:**
  - `bash -n` on all 5 changed files: clean.
  - Suite-wide re-grep after fixing: `grep -rln "python3 << [A-Z]"
    --include='*.sh' . | grep -v "<< '"` → zero results (was 5).
  - Suite-wide `bash -n` re-run across every `*.sh` file in the project
    (not just the 5 touched) to confirm no collateral breakage: all pass.
  - **Adversarial live test** on the directly-exploitable one
    (`update-watermark.sh`): ran with
    `--timestamp 'x"; import os; os.system("touch /tmp/PWNED_$$"); x="'`
    against a real workspace. Confirmed (a) `/tmp/PWNED_*` was never
    created — no code executed — and (b) the watermark JSON stored the
    full payload as a correctly-escaped inert string
    (`"timestamp": "x\"; import os; os.system(...); x=\""`), proving both
    the injection AND a secondary risk (unescaped quotes corrupting the
    JSON output) are closed.
  - **Functional regression check** on the 4 non-directly-exploitable
    files: built a real `index.json`/`habit-state.json` fixture and ran
    `load-core.sh` (default threshold) and `sync-core.sh` (custom
    `THRESHOLD=0.4` env var) end-to-end — output content and the
    `≥ 0.4` threshold line in the generated `HIPPOCAMPUS_CORE.md` matched
    expectations exactly, confirming the `os.environ` conversion didn't
    change behavior, only closed the injection path.

### Deliberately left alone
- `skills/acc-error-memory/scripts/update-watermark.sh`'s *other* Python
  invocation (the `--from-pending` branch, `python3 -c "import os\n\nimport
  json\n..."`) — already uses `PENDING_FILE="$PENDING_FILE" python3 -c
  "...os.environ['PENDING_FILE']..."`, i.e. it was already fixed correctly
  in an earlier round. Left untouched.

---

## [Round 5] — 2026-07-11

### Found via
`shellcheck -S style` across all `*.sh` files (strictest level, previous
rounds only went to `-S warning`), plus root-causing two warnings that Round
4 had logged as "harmless false positives" instead of actually fixing.

### Bug: `SC1078`/`SC2140` false positives in `decide.sh` (root cause, not just noise)
- **Root cause:** the scoring logic was embedded via `python3 -c "..."`
  (bash-double-quoted), which forced every internal Python double-quote —
  f-strings like `f\"active goal '{...}'\"`, and a comment containing
  `# is "shaky";` — to be backslash-escaped to survive bash's quoting. That
  escaping is exactly what confused shellcheck's quote parser. Previously
  this was logged as "confirmed harmless false-positive" and left alone;
  that only treats the symptom.
- **Files:** `skills/prefrontal-cortex-memory/scripts/decide.sh`
- **Fix:** converted the block from `python3 -c "..."` to a single-quoted
  heredoc (`python3 << 'PYTHON'`). Bash performs zero expansion or
  processing inside a quoted heredoc, so none of the internal Python quotes
  need escaping at all, and shellcheck no longer has anything to
  misparse. Values that previously relied on bash string-interpolation
  (including the five `/tmp/pfc_*.$$` temp-file paths) are now passed
  through as environment variables and read via `os.environ[...]`, same
  pattern as every other injection fix in this file's history.
- **Verified:**
  - `shellcheck -S style` on the file: zero findings (was 2).
  - `bash -n` clean.
  - Isolated live test of the extracted heredoc with
    `CONTEXT="user's request; import os; print('PWNED')"` — output shows
    the full payload string returned verbatim inside the JSON `context`
    field, not executed.
  - This suite has an `install.sh --wake-hour`/`decide.sh --context`-style
    manual-fix list that keeps getting dropped when the project is
    re-exported from elsewhere (see Round 3–5 entries below) — if this
    happens again, check `skills/prefrontal-cortex-memory/scripts/decide.sh`
    for the heredoc form specifically; if it's back to `python3 -c "..."`,
    the injection fix was reverted too.

### Bug: `SC2129` in `dashboard-builder.sh` — grouped-redirect nit, fixed for real this round
- **Root cause:** the last third of the script wrote to `$OUTPUT_FILE` via
  five separate `cat >> "$OUTPUT_FILE" << HEREDOC` / `echo >> "$OUTPUT_FILE"`
  calls in sequence (with one small bash `for` loop interleaved), each
  reopening the file. Purely a performance/style issue, not a correctness
  bug — but Round 4 declined to fix it citing restructuring risk across 11
  duplicated copies. This round did it properly instead of leaving it.
- **Files:** `skills/*/scripts/dashboard-builder.sh` — this file is
  intentionally byte-identical across all 11 skill directories (confirmed
  via `md5sum skills/*/scripts/dashboard-builder.sh | awk '{print $1}' |
  sort -u` → 1 unique hash). Fixed once in
  `skills/prefrontal-cortex-memory/scripts/dashboard-builder.sh`, verified,
  then propagated byte-for-byte to the other 10.
- **Fix:** wrapped the whole tail (`FOOTER` heredoc → `JSDATA` heredoc →
  `JSCORE` heredoc → `$JS_SCRIPTS` echo → `JSEND` heredoc) in a single
  `{ ... } >> "$OUTPUT_FILE"` group, with the interleaved `FIRST_ID` bash
  loop left inside the group (group commands can contain arbitrary bash).
  The final `echo "🧠 Dashboard generated: ..."` stays *outside* the group
  since it's a stdout status message, not file content. The one
  intentionally-unquoted heredoc delimiter (`<< JSDATA`, needs `$FOCUS_ID`/
  `$FIRST_ID`/`$JS_STATE_ENTRIES` expansion) was left unquoted; the two that
  are pure static template (`FOOTER`, `JSCORE`, `JSEND`) stayed quoted.
- **Verified:**
  - `shellcheck -S style` on the file: zero findings (was 1).
  - `bash -n` clean.
  - Live run: `WORKSPACE=/tmp/tw bash
    skills/prefrontal-cortex-memory/scripts/dashboard-builder.sh --focus
    prefrontal` against an empty fragments dir — produced a complete,
    correctly-terminated `brain-dashboard.html` (verified the tail contains
    the full `<script>...</script></body></html>` block, not truncated).
  - After propagating to all 11 copies: `md5sum` re-check confirms all 11
    are still identical to each other.

### Reapplied from prior rounds (this was a fresh, unfixed export)
This upload (`AI_Daemon_Brain_fixed-CORRECTED.zip`) did not contain any of
the fixes below — it was a clean/regressed baseline, not derived from the
Round 4 output. All of the following were reapplied and reverified in this
round; see the Round 1–4 entries for the original root-cause writeups:
- Python `python3 -c "...'$VAR'..."` / unquoted-heredoc injection class,
  26 files (Rounds 1–2).
- `decide.sh` `$CONTEXT`, `beat.sh` bare `$HOUR`/`$WAKE_HOUR`/`$SLEEP_HOUR`,
  heartbeat `install.sh` bare `$WAKE_HOUR`/`$SLEEP_HOUR` (Round 2).
- `hippocampus-memory/install.sh` broken duplicate arg-parsing loop using
  invalid `${@: -2:1}` array-concat syntax (Round 3).
- `acc-error-memory/scripts/encode-pipeline.sh` — `--no-spawn` parsed into
  `NO_SPAWN` but never checked; gate was present in an earlier version of
  this file and had been dropped (Round 3). **This dropped a second time**
  in the export used for this round — worth extra scrutiny if it recurs a
  third time; something in this project's export/merge process may be
  losing hand-written control-flow edits.
- `hippocampus-memory/scripts/decay.sh` — `DECAY_RATE`/`ARCHIVE_THRESHOLD`
  declared in bash but silently disconnected from a separately hardcoded
  copy inside the Python block (Round 4).
- `hippocampus-memory/scripts/summarize-pending.sh` — unquoted heredoc +
  bare (unquoted, CLI-controlled) `--batch-size` injection point (Round 4).
- `anterior-cingulate-memory/{flag-attention,log-conflict,resolve-conflict}.sh`
  — manual `sed 's/"/\\"/g'` pre-escaping before passing to `jq --arg`,
  which double-escapes and **corrupts stored data** for any topic/reason/
  description containing a literal quote character (Round 4 — this is a
  correctness bug, not just a lint nit; `jq --arg` already does its own safe
  JSON escaping, so any manual pre-escaping in front of it is wrong by
  construction).
- `SC2155` (masked return codes via `local x=$(...)`), `SC2012` (`ls` for
  glob/mtime instead of `find`), `SC2015` (fragile `A && B || C` used as
  if/else), `SC2162` (`read` without `-r`), `SC2086` (unquoted vars in
  `$(bar $x)`-style calls), and ~9 confirmed-dead variables (Round 4).

---

## [Round 4] — 2026-07-11

### Found via
`shellcheck -S warning` across all `*.sh`, followed by manual triage of
every flagged line (not blanket-applying suggestions) to separate real bugs
from pure style.

### Bug: `jq --arg` double-escaping — data corruption
- **Root cause:** `TOPIC_ESCAPED=$(echo "$TOPIC" | sed 's/"/\\"/g')` followed
  by `jq --arg t "$TOPIC_ESCAPED" ...`. `jq --arg` already performs correct,
  complete JSON-string escaping internally — that's its job. Pre-escaping
  before handing a value to it means quote characters get double-escaped in
  the stored JSON, permanently corrupting any topic/reason/description that
  contained a literal `"`.
- **Files:** `skills/anterior-cingulate-memory/scripts/flag-attention.sh`
  (2 call sites), `log-conflict.sh`, `resolve-conflict.sh`.
- **Fix:** removed all four `sed`-based pre-escaping lines; pass the raw
  variable directly to `jq --arg`.
- **Verified:** `shellcheck -S style` flagged these as `SC2001` ("use
  parameter expansion instead of sed") — a *style* suggestion — but reading
  the surrounding code (where the escaped output feeds `jq --arg`) showed
  it was actually a correctness bug, not just an inefficient pattern. This
  is the kind of thing that only shows up from reading context, not from
  the lint tool alone.

### Other fixes this round
- `SC2155`, `SC2012`, `SC2015`, `SC2162`, `SC2086` (see Round 5 summary
  above for detail — not re-duplicated here since Round 5 reapplied the
  same fixes verbatim to a later export).
- Confirmed-dead variables removed only after manually checking each one
  really was unused (a few looked dead at a glance but were actually read
  from inside an embedded Python heredoc, which `shellcheck` can't see into
  — those were NOT removed, they were reconnected properly instead; see
  `decay.sh` DECAY_RATE/ARCHIVE_THRESHOLD entry above).

### Deliberately left alone (this round)
- `SC2129` (grouped redirects in `dashboard-builder.sh`) — logged as
  "genuinely style-only, restructuring risk not worth it across 11
  duplicated files." **Revisited and fixed properly in Round 5** — see
  above. Lesson: "not worth the risk" is a judgment call that can change
  once you actually look at the full picture; don't treat a prior "leave
  it" as permanent without re-examining.

---

## [Round 3] — 2026-07-11

### Found via
`shellcheck -S error` (first pass at zero severity threshold) plus manual
read of every `--no-spawn`/flag-parsing block after finding the first
broken one.

### Bug: broken duplicate arg-parsing loop
- **Root cause:** `hippocampus-memory/install.sh` had two separate
  arg-parsing passes over `"$@"`. The first used `${@: -2:1}` (invalid
  bash array-slice syntax outside array context) and an unreliable
  `prev_arg` variable that only worked by accident. The second, correct
  `while [[ $# -gt 0 ]]` loop happened to run afterward and silently
  overwrote whatever the first loop got wrong — so the bug was invisible
  in normal operation, but the first loop was genuinely broken code
  (`shellcheck -S error`, not just a style nit).
- **Files:** `skills/hippocampus-memory/install.sh`.
- **Fix:** deleted the broken first loop, kept only the correct
  `while`-based one (extended to also set `WITH_CRON`/`WITH_AGENT`, which
  only the broken loop had been setting).
- **Verified:** `shellcheck -S error` zero on the file; live run with
  `--with-cron --signals 42` showed both flags correctly applied.

### Bug: dropped `--no-spawn` gate
- **Root cause:** `acc-error-memory/scripts/encode-pipeline.sh` parsed
  `--no-spawn` into `NO_SPAWN=true` but nothing in the script ever checked
  the variable — the flag was a complete no-op. Comparing against an
  earlier version of this same script (seen in an unrelated debugging
  transcript) showed the gate used to exist:
  `if [ "$NO_SPAWN" = true ]; then echo "Skipping..."; exit 0; fi`
  immediately before the LLM-screening step. It had been dropped at some
  point between exports.
- **Files:** `skills/acc-error-memory/scripts/encode-pipeline.sh`.
- **Fix:** restored the gate before Step 4 (LLM screening).
- **Verified:** live run with `--no-spawn` against a workspace with a
  pending-errors file exits before reaching the LLM-screening step.
- **Note:** this same gate was found dropped *again* in the Round 5 export.
  See the Round 5 note above — this specific regression has now recurred
  twice across different exports of this project.

---

## [Round 1–2] — 2026-07-07 to 2026-07-11

### Found via
A prior debugging transcript had already *identified* (via `grep -rln
'python3 -c "' --include='*.sh'`) that ~27 scripts built `python3 -c "..."`
commands by splicing shell variables directly into single-quoted Python
string literals, but that session ended after triage without applying any
fix. Round 1 discovered the fixes described in that transcript had never
actually been applied to the delivered project — this was independently
re-confirmed by re-running the same grep against the delivered code.

### Bug: shell-to-Python string injection (the core vulnerability class of this whole project)
- **Root cause:** patterns like
  `RESULT=$(... python3 -c "... '$CONTEXT' ...")` rely on bash performing
  variable substitution *before* Python ever sees the string, then wrapping
  the substituted value in Python single-quotes. Any value containing an
  apostrophe breaks the generated Python syntax; any value containing
  `'; <arbitrary code>; '` executes as Python. `decide.sh`'s `--context`
  flag took free-text input directly from the CLI into this pattern — the
  most directly exploitable instance, but the same shape existed in 26
  other files, plus a few using unquoted heredocs (`python3 << PYEOF` with
  no delimiter quoting, which bash still expands the same way).
- **Files:** 26 files across nearly every skill (`prefrontal-cortex-memory`,
  `basal-ganglia-memory`, `cerebellum-memory`, `acc-error-memory`,
  `vta-memory`, `amygdala-memory`, `social-memory`,
  `anterior-cingulate-memory`, `heartbeat-memory`, `hippocampus-memory`) —
  see git history / prior round diffs for the exhaustive list, or re-run
  `grep -rln "python3 -c \"" --include='*.sh' .` combined with
  `grep -rln 'python3 <<' --include='*.sh' .` to reconstruct it.
- **Fix:** every value is now passed as an environment variable
  (`VAR="$shell_var" python3 -c "..."`) and read inside Python via
  `os.environ['VAR']`, instead of being spliced into Python source text.
  This is immune to the value's content by construction — no escaping
  logic to get wrong.
- **Verified:**
  - `bash -n` on every changed file.
  - `python3 -m ast.parse` (via a small verification script) on every
    extracted embedded Python block.
  - **Adversarial live test**, the gold-standard check for this bug class:
    `CONTEXT="user's request; import os; print('PWNED')"` passed through
    the real fixed code path — output showed the entire string returned
    intact inside the JSON result, not executed and not breaking anything.
    Re-run in every subsequent round to catch regressions.
- **Also found while fixing this:** `heartbeat-memory/install.sh` spliced
  `--wake-hour`/`--sleep-hour` into Python **completely unquoted** (not
  even wrapped in Python quotes) — an even easier injection point than the
  quoted cases, and one the original transcript's `grep` had missed
  entirely because it only searched for the quoted pattern. Lesson: a
  single grep pattern for a bug class will miss variants; check the
  unquoted/bare-interpolation case too.
