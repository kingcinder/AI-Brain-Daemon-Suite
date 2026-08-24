# Live Deployment Runbook — Post-Architecture Rollout

This runbook guides the transition from architecture-proven-in-sandbox to
trusted-in-production. Each phase has concrete steps, success criteria, and
a go/no-go checkpoint before advancing.

**Pre-requisite:** All 7 architecture phases are committed and passing
(ci-gate green, 48/48 tests). No live `memory/` state exists in the repo
(correctly — it's runtime state).

---

## Phase 1: Close M0 — Real-Host Verification

**Goal:** Confirm the daemon runs correctly on actual hardware, not just in
test sandboxes.

### Steps

1. **Run SETUP_COMMANDS.md end-to-end on your actual box**
   ```bash
   # From the repo root:
   bash install.sh --yes
   ```

2. **Confirm `--check` passes**
   ```bash
   WORKSPACE=~/.hermes/workspace DEEP_BRAIN_KERNEL_SKIP_HERMES_CHECK=1 \
     python3 deep-brain-kernel.py --check
   ```
   Expected: "✅ All checks passed." with 30 jobs, all ok.

3. **Confirm `--check-runtime` passes**
   ```bash
   python3 deep-brain-kernel.py --check-runtime
   ```
   Expected: "RUNTIME CHECK OK: /run/user/<uid>/aibrain" with exit 0.
   If exit 1 → you're not running under systemd --user, fix that first.

4. **Confirm PSI deferral fires during a real spawn job**
   ```bash
   # Start the daemon:
   systemctl --user start aibrain.service
   # Wait for a spawn job to fire (check journalctl):
   journalctl --user -u aibrain.service -f
   # Look for "PSI deferral" in the log — confirms pressure-based job deferral works
   ```

5. **Confirm GPU VRAM deferral fires**
   ```bash
   # Check that the daemon reads VRAM correctly:
   python3 deep-brain-kernel.py --brain --json | jq '.daemon.vram'
   # Should show actual VRAM usage percentage, not "unavailable"
   ```

6. **Confirm cgroup delegation**
   ```bash
   systemctl --user show aibrain.service | grep -i cgroup
   # Should show CPUQuota, MemoryMax, or similar cgroup settings
   ```

7. **Run for 24h with `--status` showing zero unhealthy jobs**
   ```bash
   # After 24 hours:
   python3 deep-brain-kernel.py --status
   ```
   Expected: all jobs with consecutive_failures = 0.

### Success Criteria
- [ ] `--check` passes (30 jobs, all ok)
- [ ] `--check-runtime` exits 0 (real XDG runtime dir)
- [ ] PSI deferral observed in journalctl
- [ ] GPU VRAM reading works (not "unavailable")
- [ ] Cgroup settings visible in systemctl show
- [ ] 24h with zero unhealthy jobs

### Go/No-Go
If any criterion fails, do NOT advance to Phase 2. Fix the issue first.

---

## Phase 2: Tier-0 Supervised Live Run

**Goal:** First real graduation streak — every proposal requires human
approval. Track approve/reject ratio.

### Steps

1. **Enable LLM-full-patch mode**
   ```bash
   # In the daemon's environment (e.g., aibrain.service Environment=):
   LLM_FULL_PATCH=1
   ```

2. **Restart the daemon**
   ```bash
   systemctl --user restart aibrain.service
   ```

3. **Wait for `self_mod_proposal_cycle` to fire** (weekly, Saturday 03:46)
   ```bash
   journalctl --user -u aibrain.service --since "today" | grep proposal
   ```

4. **Review every proposal**
   ```bash
   # List proposals:
   ls ~/.hermes/workspace/memory/self-mod/proposals/
   # Read each one:
   for f in ~/.hermes/workspace/memory/self-mod/proposals/prop_*.json; do
     echo "=== $(basename $f) ==="
     jq '{module, description, status}' "$f"
   done
   ```

5. **Approve or reject each proposal**
   ```bash
   # Approve:
   bash core/self-mod/proposal-store.sh set-status --id <PROPOSAL_ID> --status accepted
   # Reject (with reason):
   bash core/self-mod/proposal-store.sh set-status --id <PROPOSAL_ID> --status rejected
   # Then annotate the reason:
   jq '.reject_reason = "too broad, wrong target"' <proposal>.json > tmp && mv tmp <proposal>.json
   ```

6. **Track your approve/reject ratio**
   ```bash
   # After a few cycles:
   ACCEPTED=$(ls ~/.hermes/workspace/memory/self-mod/proposals/*.json | \
     xargs jq -r '.status' | grep -c accepted)
   REJECTED=$(ls ~/.hermes/workspace/memory/self-mod/proposals/*.json | \
     xargs jq -r '.status' | grep -c rejected)
   echo "Ratio: $ACCEPTED accepted / $REJECTED rejected"
   ```

### Success Criteria
- [ ] Daemon generates real proposals (not test fixtures)
- [ ] You can read and understand each proposal
- [ ] Approve/reject ratio is tracked
- [ ] Rejection reasons are documented in proposal JSON
- [ ] 7 consecutive healthy days achieved
- [ ] Verification pass rate ≥ 90%

### Go/No-Go
Promote to Tier 1 when:
- `check-tier.sh` reports `promotion_eligible: true`
- You've manually reviewed at least 5 proposals
- You're satisfied with the proposal quality trend

```bash
# Check eligibility:
bash core/self-mod/check-tier.sh --workspace ~/.hermes/workspace | jq '.promotion_eligible'
```

---

## Phase 3: Tier-1 Sandbox Trust Window (14 days)

**Goal:** Auto-deploy to sandbox + auto-rollback, unsupervised, for the full
14-day observation window.

### Steps

1. **Promote to Tier 1**
   ```bash
   bash core/self-mod/check-tier.sh --workspace ~/.hermes/workspace \
     --promote --reason "Phase 2 supervised run complete, promotion criteria met"
   ```

2. **Verify tier state**
   ```bash
   jq '.' ~/.hermes/workspace/memory/self-mod/autonomy-tiers-state.json
   # Should show current_tier: 1
   ```

3. **Let it run for 14 days** — don't intervene unless something breaks.
   The daemon will:
   - Generate proposals from real signals
   - Rank them with verification/ACC/calibration boosts
   - Arbitrate against active goals
   - Auto-deploy to sandbox copy
   - Auto-rollback on regression

4. **Monitor daily** (5 minutes)
   ```bash
   # Quick health check:
   python3 deep-brain-kernel.py --status | grep unhealthy
   # Check recent deployments:
   ls ~/.hermes/workspace/memory/self-mod/deploys/ | tail -5
   # Check for rollbacks:
   jq '.status' ~/.hermes/workspace/memory/self-mod/deploys/*.json | grep rolled_back
   ```

5. **After 14 days, evaluate**
   ```bash
   bash core/self-mod/check-tier.sh --workspace ~/.hermes/workspace | jq '{
     current_tier, promotion_eligible, promotion_reasons, state
   }'
   ```

### Success Criteria
- [ ] 14 consecutive days of daemon uptime
- [ ] Zero rollbacks (or rollbacks that worked correctly)
- [ ] Verification pass rate ≥ 95%
- [ ] At least 3 proposals generated and evaluated
- [ ] No manual intervention required (the system self-managed)

### Go/No-Go
Promote to Tier 2 when `check-tier.sh` reports `promotion_eligible: true`
and you've confirmed the rollback system actually worked at least once
(either a real rollback or a sandbox evaluation that correctly rejected a
bad proposal).

---

## Phase 7: Re-Run Stage 3 Readiness Review

**Goal:** Compare live evidence against the sandboxed review from
`docs/2026-08-24-stage3-readiness-review.md`.

### Steps

1. **Collect live evidence**
   ```bash
   # Graduation streak:
   jq '.' ~/.hermes/workspace/memory/self-mod/graduation-streak.json
   # Tier state:
   jq '.' ~/.hermes/workspace/memory/self-mod/autonomy-tiers-state.json
   # Proposal history:
   echo "Accepted: $(jq -r '.status' ~/.hermes/workspace/memory/self-mod/proposals/*.json | grep -c accepted)"
   echo "Rejected: $(jq -r '.status' ~/.hermes/workspace/memory/self-mod/proposals/*.json | grep -c rejected)"
   echo "Rolled back: $(jq -r '.status' ~/.hermes/workspace/memory/self-mod/deploys/*.json | grep -c rolled_back)"
   # Verification history:
   jq '.pass_rate' ~/.hermes/workspace/memory/verification-state.json
   ```

2. **Write `docs/YYYY-MM-DD-stage3-readiness-review-live.md`** comparing:
   - Sandbox prediction vs live outcome for each criterion
   - Real approve/reject ratio vs assumed quality
   - Real rollback count vs assumed safety
   - Real graduation streak vs assumed timeline

3. **If live evidence matches sandbox prediction:** the system has earned
   its autonomy. Proceed toward Tier 3 consideration.

4. **If live evidence falls short:** identify the gap, adjust the tier
   criteria, and extend the observation window. Do not advance on hope.

---

## Tier-4 Documentation Fix (Phase 4 of this rollout)

Already implemented:
- `autonomy-tiers.json` Tier 3 now explicitly lists `immutable_core_modification`
  in `blocked_actions` with a `blocked_actions_note` explaining that
  `check-target.sh` enforces this unconditionally.
- `check-tier.sh --promote/--demote` writes provenance events via
  `log-provenance.sh` when a tier change occurs.

## Proposal Feedback Loop (Phase 5 of this rollout)

Already implemented:
- `generate-proposals-llm.sh` now collects rejection reasons from the
  proposal store and injects them into the LLM prompt as
  `HUMAN REJECTION REASONS (JSON — proposals the human rejected; avoid
  these patterns)`.

## Deploy Scope Restriction (Phase 6 of this rollout)

Already implemented:
- `autonomy-tiers.json` now includes a `deploy_scope` section with
  `tier_2_initial_scope` restricted to `heartbeat-memory` and
  `cerebellum-memory` for the first live production auto-deploys.
