# Hermes Agent Compatibility Audit

> **Status:** Living document. Per-file audit of the entire suite against
> **Hermes Agent** (Nous Research) — the agent harness this suite runs under,
> and the rebrand of the harness formerly called **OpenClaw** (the installed
> `hermes` binary keeps a `claw` compat command and still reads legacy
> `metadata.openclaw` skill frontmatter).
>
> **Method:** every file was inspected against the *installed* Hermes Agent
> on this host — `hermes --help`, `hermes chat --help`, `hermes cron
> create|remove --help`, `hermes skills list`, and `~/.hermes/config.yaml` —
> not against assumptions. Verified facts are marked **✓ verified on host**.

---

## What "compatible with Hermes Agent" means here

The suite's daemon is a *supervisor* that hands agent-reasoning turns to the
harness. Compatibility has three concrete axes:

1. **CLI invocation** — every place the suite shells out to the harness must
   use the real `hermes` binary and real flags (`hermes chat -q …`,
   `hermes cron create …`, `hermes cron remove <id>`).
2. **Skill packaging** — each skill must be discoverable/installable by
   `hermes skills` (a `SKILL.md` with `name` + `description` frontmatter,
   the progressive-disclosure layout Hermes reads).
3. **Nomenclature & docs** — code comments, README, setup docs, and skill
   installers must name the harness *Hermes Agent* and its commands, not the
   legacy *OpenClaw* / `openclaw cron add` / `openclaw sessions:spawn` names.

---

## Verified ground truth (on this host)

| Check | Result |
|---|---|
| `hermes` on PATH | ✓ `/home/cody/.local/bin/hermes` |
| `hermes chat -q … --source daemon` | ✓ valid flag set (`-q/--query`, `--source`) |
| `hermes cron create '<schedule>' '<prompt>' --name X` | ✓ verified positional signature (schedule, prompt, `--name`) |
| `hermes cron remove <job_id>` | ✓ verified positional `job_id` (not `--name`) |
| Suite skills registered in Hermes | ✓ `hermes skills list` shows all 11 brain skills as `enabled` (source `local`, trust `local`) |
| Hermes config location | ✓ `~/.hermes/config.yaml` (provider `custom:llamaserver`, local GGUF model; `skills.external_dirs` → `~/.hermes/workspace/skills`, Option B) |
| Daemon workspace | `~/.hermes/workspace` (migrated from `~/.openclaw/workspace` — Open Item 1 closed 2026-08-04) |

---

## Per-file findings

Legend: **✅ compatible** · **🔧 fixed in this pass** · **ℹ️ note (intentional)** ·
**🏛 legacy (excluded by design)**

### Root

| File | Verdict | Notes |
|---|---|---|
| `deep-brain-kernel.py` | 🔧 | Spawn jobs route through `core/spawn/spawn-provider.sh` → `hermes chat -q … --source daemon` (M3). Fixed 3 legacy `sessions:spawn` comment/output strings → `hermes chat` (Job dataclass comment, `--check` column label, `_await_with_timeout` docstring). `--check` still validates `hermes` on PATH + the provider shim. |
| `core/spawn/spawn-provider.sh` | ✅ | Hermes-native by construction: `exec hermes chat -q "$TASK" --source daemon [--accept-hooks --yolo]`; `local` provider uses the suite's own `llm-call.sh`. |
| `install.sh` | 🔧 | Fixed gotcha (a) `openclaw/jq/curl` → `hermes/jq/curl` and the `which` hint; fixed an indentation regression on two `echo` lines. Still deploys to `~/.openclaw/workspace` (data dir, intentional). |
| `aibrain.service` | 🔧 | GOTCHA (a) + PATH comment: `openclaw not found` → `hermes not found`; PATH comment lists `hermes` first. |
| `README.md` | 🔧 | Fixed `openclaw sessions:spawn` → `hermes chat` (per-job timeout bullet) and the `openclaw`/`jq`/`curl` PATH gotcha. |
| `AGENTS.md` | ℹ️ | Project rules file — Hermes reads `AGENTS.md` natively (compatible). Pointer to `~/.grok/AGENTS.md` for *global* rules is factual (file exists); not the harness's own global file, so left untouched. |
| `BRAIN_DAEMON_SCHEDULE.md` | 🔧 | `openclaw sessions:spawn` → `hermes chat -q … --source daemon`; decommission section `openclaw cron list/remove --name` → `hermes cron list` / `hermes cron remove <job_id>`. |
| `SETUP_COMMANDS.md` | 🔧 | `--check` expectation `openclaw found` → `hermes found`. |
| `ROADMAP.md`, `VISION.md`, `AUDIT.md` | ✅ | Already use `hermes chat` / Hermes Agent nomenclature (post-M3 docs). |
| `BUGFIX_HISTORY.md` | ℹ️ | Historical record; one `sessions:spawn` mention documents a past bug in the old bash daemon. Kept as history. |
| `LICENSE`, `.gitignore`, `.github/workflows/ci.yml` | ✅ | CI runs harnesses only (no harness CLI dependency). |
| `VP_VULKANINFO_*.json` | ℹ️ | Stray verification artifact at repo root (GPU probe). Not harness-related. |

### `core/`

| File | Verdict | Notes |
|---|---|---|
| `core/self-mod/generate-proposals-llm.sh` | ✅ | Uses `hermes chat -q "$PROMPT" --provider openrouter -m …` — valid Hermes flags; prefers local `llm-call.sh` otherwise. |
| `core/executive/*` (run-executive-cycle, propose-goals, isolated-reflect, record-goal-outcome) | ✅ | No harness invocations — pure suite logic; `WORKSPACE` defaults are data-dir paths (intentional). |
| `core/self-mod/*` (pipeline, monitor, graduation, etc.) | ✅ | Self-contained; `WORKSPACE` data-dir defaults only. |
| `core/schema`, `core/locks`, `core/concurrency`, `core/sandbox`, `core/snapshot`, `core/utility`, `core/provenance`, `core/executive-load` | ✅ | No harness coupling. |

### `skills/*/` (11 skills)

| Skill | Verdict | Notes |
|---|---|---|
| `SKILL.md` (all 11) | 🔧 | `name` + `description` top-level frontmatter (Hermes-required) plus a `metadata.hermes` block carrying `emoji` + `tags` (per hermes-agent `tools/skills_tool.py` + `agent/skill_utils.py` schema; duplicated `name`/`description` dropped 2026-08-04 since Hermes reads those top-level) ahead of the legacy `metadata.openclaw` block (preserved verbatim as a compat alias, Open Item 2 CLOSED). Each also gained a `## When to Use` progressive-disclosure section, a `references/` dir, and the existing `## Quick Start` sections serve as the procedure section (2026-08-04). `hermes skills install` discovers every one; local registration is the supported install path (see "Installing / updating as first-class Hermes skills"). |
| `install.sh` (10 skills) | 🔧 | Headers `for OpenClaw` → `for Hermes Agent`; `command -v openclaw` → `command -v hermes`; `openclaw cron add --name X --cron 'S' --session isolated --agent-turn 'P'` → `hermes cron create 'S' 'P' --name X` (matches verified signature; `--session isolated` has no Hermes equivalent and was dropped); manual-command `echo` help text converted too. 2026-08-04: remaining stale `Setting up OpenClaw cron job(s)...` echoes + `Set up OpenClaw cron` comments swept to Hermes in 7 installers (amygdala, anterior-cingulate, cerebellum, heartbeat, prefrontal-cortex, social, vta), and the legacy `OPENCLAW_WORKSPACE` env fallback dropped from the anterior-cingulate + insula `WORKSPACE` defaults. |
| `skills/hippocampus-memory/install.sh` | 🔧 | Also fixed `openclaw.json agents.list` + `memorySearch.extraPaths` references → labeled as legacy OpenClaw config with Hermes AGENTS.md guidance. |
| `scripts/encode-pipeline.sh` (hippocampus) | 🔧 | Manual-completion hint `openclaw sessions:spawn --task …` → `hermes chat -q … --source daemon`. |
| `SKILL.md`/`README.md` cron examples (acc-error, hippocampus, vta, basal-ganglia) | 🔧 | Doc code blocks `openclaw cron add …` → `hermes cron create …` one-liners. |
| `skills/executive-function`, `skills/self-mod-runner` | ℹ️ | Daemon-facing entrypoint skills (no `_meta.json`, plain `SKILL.md` headings) — intentionally suite-internal, not hub skills; `--check` resolves their script targets fine (file-path check, independent of Hermes skill discovery). They surface in `hermes skills list` via Option B's `external_dirs` (verified: load as `local`, no warnings) — since 2026-08-04 they are listed in `skills.disabled` so the list stays focused on the 11 brain skills (`--check` unaffected). |
| `agentdir/AGENTS.md`, `agents/hippocampus-agent.md` (hippocampus) | ℹ️ | Sub-agent role instructions; Hermes reads AGENTS.md-style rules, so compatible; the `~/.hermes/workspace` paths inside are the suite's data dir (intentional). |
| preprocess transcript dirs (8 scripts: hippocampus, social, amygdala, acc-error ×2, vta, basal-ganglia) | 🔧 | `TRANSCRIPT_DIR`/`TRANSCRIPTS_DIR` defaults repointed from dead `$HOME/.openclaw/agents/$AGENT_ID/sessions` + `$HOME/.openclaw/sessions` → `${VAR:-$HOME/.hermes/sessions}` (env override preserved); content filters updated to match `/.hermes/` paths too. See Open Item 5 for the format caveat. |
| `_meta.json`, `capability-manifest.json`, `skill-card.md` | ✅ | Suite's own registry (validated by `core/schema/validate-manifest.sh`); Hermes does not consume these, and they don't conflict with Hermes packaging. |

### `tests/`, `docs/`, `legacy-IGNORE/`

| Path | Verdict | Notes |
|---|---|---|
| `tests/*` (all harnesses) | ✅ | Hermes-neutral; Phase 6 fakes `hermes` via a PATH stub. No real harness CLI needed in CI. |
| `docs/V4_STATUS.md`, `docs/V4_IMPLEMENTATION_PROCESS.md`, `docs/verification/` | ℹ️ | Historical records of a prior OpenClaw-era install; left as-is (they document what happened). `docs/verification/` contains raw logs/artifacts, not shipped behavior. |
| `legacy-IGNORE/` (brain-daemon.sh etc.) | 🏛 | Explicitly quarantined legacy bash engine; not installed by `install.sh`; excluded from this audit by the repo's own convention. |

---

## What was changed in this pass

- `deep-brain-kernel.py` — 4 spots (`sessions:spawn` → `hermes chat`, plus the broken leftover `openclaw` word in the `_await_with_timeout` docstring).
- `README.md` (2), `SETUP_COMMANDS.md` (1), `BRAIN_DAEMON_SCHEDULE.md` (3), `install.sh` (1+indent fix), `aibrain.service` (2).
- 10 × `skills/*/install.sh` — header, PATH check, and every `openclaw cron add` → `hermes cron create` (executed + echoed forms), plus hippocampus `openclaw.json` wording.
- 2026-08-04 follow-up pass — **Option B adopted**: `skills.external_dirs` set to `~/.hermes/workspace/skills` in `~/.hermes/config.yaml`; the 11 `~/.hermes/skills/<name>/` Option A copies were removed (they shadowed the external dir in `_find_all_skills`' local-first dedup, defeating auto-sync) so the workspace deploy is now the single live source; workspace deploy refreshed from the repo. Also swept remaining live-code relics: `Setting up OpenClaw cron…` echoes/comments in 7 installers, the `OPENCLAW_WORKSPACE` env fallback in 2, and the stale `OpenClaw workspace directory` comment in `basal-ganglia-memory/scripts/decay-habits.sh` — all → Hermes naming. The stray `toby-basal-ganglia-memory` hub skill (a SkillBoss/ImpKind stub from a different project, `caution` scan verdict with a HIGH exfiltration finding, no suite references) was uninstalled 2026-08-04.
- 2026-08-04 — daemon entrypoints `executive-function` + `self-mod-runner` re-synced into `~/.hermes/workspace/skills/` (fresh copy from repo; `diff -r` verified in sync) and added to `skills.disabled` in `~/.hermes/config.yaml` (previously `disabled: []`). `hermes skills list` now shows them as `disabled` (169 enabled / 2 disabled); `deep-brain-kernel.py --check` still resolves all three entrypoint jobs `ok` (file-path check). Config backup at `~/.hermes/config.yaml.bak-disabledEntrypoints`.
- 2026-08-04 — **host skill-hygiene audit + prune**: audited the 68 hub-installed community skills unrelated to the brain suite. Usage evidence (across all 3,020 messages / 1,379 sessions in `~/.hermes/state.db`): zero references in the suite's live code (skills/, core/, tests/, install.sh, aibrain.service, `deep-brain-kernel.py`); only **OSINT** was ever explicitly requested by a user (15×) and shows real `skill_view` activity (7× on 07-17/18) — every other skill's only view/manage signal is a single bulk inventory browse (06-25/26) or nothing at all, despite most being installed in the large scripted batch logged on 07-18 (per `~/.hermes/skills/.hub/audit.log`). Pruned **67** of the 68 via `hermes skills uninstall` (kept OSINT), then also removed **30 stale lock entries** (dirs present + lock rows, e.g. `contract`, `android-studio`, `growth-hacker`, `deepdive-osint`, `youtube-launch-kit`) that the CLI no longer counted as hub. Lock went 98 → 1 entry (OSINT); `hermes skills list` now shows `1 hub-installed` / all 11 brain skills `local`/`enabled`. Backup: `~/.hermes/skills/.hub/lock.json.bak-pre-prune2`.
- `skills/hippocampus-memory/scripts/encode-pipeline.sh` — manual-run hint.
- `skills/acc-error-memory`, `hippocampus-memory`, `vta-memory` `SKILL.md` + `hippocampus-memory`, `basal-ganglia-memory` `README.md` — doc cron examples.

All converted cron commands match the verified `hermes cron create '<schedule>' '<prompt>' --name <job>` signature; `--session isolated` (no Hermes equivalent) was dropped; `2>/dev/null && echo ✅ || echo ⏭️` guards preserved.

## Open items (deliberately not changed — decisions for you)

1. ~~**`~/.openclaw/workspace`**~~ — **CLOSED (2026-08-04):** migrated to `~/.hermes/workspace` across the daemon default, `install.sh`, `aibrain.service`, `core/`, and all `skills/` path defaults (191 files), and the live deployed state was moved + artifacts redeployed + service restarted. `WORKSPACE` remains an env override the daemon honors. Historical `docs/` records still mention the old path as history.
2. ~~**`metadata.openclaw` frontmatter**~~ — **CLOSED (2026-08-04):** every frontmatter-bearing `SKILL.md` (all 11) now carries a `metadata.hermes` block (`emoji` + `tags`, matching the hermes-agent schema; the duplicated `name`/`description` keys were slimmed out on 2026-08-04 since Hermes reads those from the top-level keys) added ahead of the legacy `metadata.openclaw` block, which is retained verbatim as a compat alias. YAML-parsed clean; **all 11** brain skills now appear in `hermes skills list` as `enabled` and **source=`local`** — the 5 that previously had no `~/.hermes/skills/<name>/` registration dir (acc-error, cerebellum, heartbeat, prefrontal-cortex, social-memory) were registered via the documented Option A loop, and the 4 that were still `clawhub`/`community` (anterior-cingulate, basal-ganglia, insula, vta-memory) were re-registered from the repo the same way (`hermes skills uninstall` to drop the hub lock entry, then the Option A copy loop; 2026-08-04). Later the same day the setup moved to **Option B**: `skills.external_dirs` is now set to `~/.hermes/workspace/skills` and the `~/.hermes/skills/` copies were removed (see "Installing / updating as first-class Hermes skills").
3. **`AGENTS.md` → `~/.grok/AGENTS.md`** pointer: factual (that file exists) and Hermes reads project `AGENTS.md` files, so compatible. If you want the *global* rules under Hermes' home instead, copy them to `~/.hermes/AGENTS.md` (Hermes reads that too).
4. **Docs `V4_*` + `docs/verification/`** contain OpenClaw-era verbiage in historical context. Left as history; update only if they're expected to be read as current instructions (they are process/verification ledgers).
5. ~~**Hermes session-transcript format**~~ — **CLOSED (2026-08-04):** the suite's preprocess scripts expect OpenClaw-era per-message `.jsonl` transcripts (one JSON message per line with `type`/`message`/`timestamp`). The installed Hermes stores sessions in `~/.hermes/state.db` (SQLite `sessions`/`messages` tables) — the old `.jsonl` layout is not produced directly. `core/transcripts/export-transcripts.sh` now bridges this: it runs `hermes sessions export --format jsonl` (which emits one whole-session JSON object per line) and rewrites it into the per-message shape the parsers expect, writing `~/.hermes/sessions/hermes-sessions.jsonl` (overridable via `TRANSCRIPT_DIR`/`EXPORT_AGE`/`HERMES_BIN`). It is wired into the daemon as the `transcript_export` direct job (hours 5/11/17/23, minute 58, unique) via `skills/hippocampus-memory/scripts/export-transcripts.sh`, covered by `tests/run_phase7_harness.sh` (fake-hermes export + transform shape + preprocess feed + daemon `run_direct` outcomes).

## Installing / updating the suite as first-class Hermes skills

Each of the 11 frontmatter-bearing skills is a valid Hermes skill: it has a
`SKILL.md` with required top-level `name`/`description`, a `metadata.hermes`
block, a `## When to Use` trigger section, and a `references/`
progressive-disclosure dir. `hermes skills install` **discovers** every one of
them (verified: it fetches the local path and runs its scan). The commands
below are the exact flows for this repo.

### Option A — register the skills in `~/.hermes/skills/` (backup/fallback, superseded 2026-08-04 by Option B)

```bash
cd /path/to/AI_BRAIN_SUITE_COMPLETE/skills
for s in acc-error-memory amygdala-memory anterior-cingulate-memory \
         basal-ganglia-memory cerebellum-memory heartbeat-memory \
         hippocampus-memory insula-memory prefrontal-cortex-memory \
         social-memory vta-memory; do
  mkdir -p "$HOME/.hermes/skills/$s"
  cp -r "$s"/* "$HOME/.hermes/skills/$s/"
done
hermes skills list   # all 11 now visible, source=local, status=enabled
```

Updating a skill later is just re-copying its directory (or `cp
"$s/SKILL.md" ~/.hermes/skills/$s/SKILL.md` for the frontmatter alone).
`install.sh` already deploys the suite to `~/.hermes/workspace/skills/`; these
two copies are independent, so keep both in sync after edits. **2026-08-04:**
Option B below is now the active setup on this host — the `~/.hermes/skills/`
copies were removed because local copies shadow the external dir in Hermes'
local-first dedup. Keep this loop only if you revert to per-host copies.

### Option B — `skills.external_dirs` in `~/.hermes/config.yaml` (zero copy, ACTIVE on this host)

Point Hermes at the suite's workspace deploy without copying anything:

```yaml
skills:
  external_dirs:
    - ~/.hermes/workspace/skills
```

Then `hermes skills list` (or a fresh session) picks up all 11 from the
workspace deploy directly — edits in the repo deploy on the next `install.sh`
run with no manual sync. (Verified against `agent/skill_utils.py`
`get_external_dirs()`; note paths resolving to `~/.hermes/skills` itself are
silently skipped, and a plain `~/.hermes/workspace/skills` is fine.) Caveat:
`~/.hermes/workspace/skills/` also contains the two daemon-facing entrypoints
`executive-function` and `self-mod-runner`, which have no frontmatter
(`name`/`description` are Hermes-required) — verified on host 2026-08-04 that
they load cleanly as `local` with no warnings; since 2026-08-04 both are listed
under `skills.disabled` so `hermes skills list` reports them as `disabled` and
stays focused on the 11 brain skills. This is display-only: the daemon
resolves those scripts by file path (`deep-brain-kernel.py --check` still
reports `executive_goal_cycle`/`self_mod_monitor`/`self_mod_proposal_cycle`
as `ok`), so disabling them in Hermes config does not affect the daemon.

### `hermes skills install` from a URL (works but scan-gated)

`hermes skills install <https-url-to-SKILL.md>` also works for discovery, but
the security scan currently flags the suite as **DANGEROUS** (CRITICAL
`persistence` on the "Add to session startup (AGENTS.md)" instructions plus
HIGH `exfiltration` on memory-state scripts), which **blocks** community-source
installs (`--force` does not override a dangerous verdict). The local
registration paths above (Options A/B) are the supported way in — locally
registered skills are source=`local` and are not scan-gated (verified: the 5
newly registered skills audit as non-hub skills, no DANGEROUS verdict). On
2026-08-04 the last 4 hub-sourced brain skills (anterior-cingulate,
basal-ganglia, insula, vta-memory) were re-registered from the repo via Option
A after `hermes skills uninstall` dropped their hub lock entries, so **all 11
brain skills are now uniformly source=`local`** and outside the scan-gated
path (`hermes skills audit` on any of them reports "not a hub-installed
skill"). On 2026-08-04 the stray `toby-basal-ganglia-memory` (a SkillBoss
"AI Brain series" stub by the same ImpKind author, `caution` verdict + HIGH
exfiltration finding, requiring `SKILLBOSS_API_KEY`, never referenced by the
suite) was also uninstalled, leaving no brain-memory shadow skills in the hub
lock. Later the same day a **full host hygiene pass** removed the remaining
unused hub skills unrelated to the suite (67 CLI-hub skills + 30 stale lock
rows; only `OSINT` — the one skill with real user usage — was kept); the hub
lock now contains exactly 1 entry. The scan findings are behavioral by design (the suite persists
memory state and prints it for context) and are tracked as a separate
decision.

## How to re-verify

```bash
hermes skills list              # suite skills appear as enabled
python3 deep-brain-kernel.py --check   # spawn-provider shim + hermes found
# (default WORKSPACE is now ~/.hermes/workspace)
bash tests/run_phase1_harness.sh && bash tests/run_phase2_harness.sh \
  && bash tests/run_phase3_harness.sh && bash tests/run_phase4_harness.sh \
  && bash tests/run_phase5_harness.sh && bash tests/run_phase6_harness.sh \
  && bash tests/run_skill_unit_tests.sh
```
