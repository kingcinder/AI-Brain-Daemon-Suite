# Phase 3 — Self-Modification Pipeline

Canonical experimental pipeline for **bounded** autonomous improvement.

## Hard rule

Never target Immutable Core paths (see `immutable-paths.list` / `IMMUTABLE.md`).
Only modules with a valid `capability-manifest.json` (`immutable: false`) may be patched.

## Scripts

| Script | Role |
|--------|------|
| `check-target.sh` | Immutable + registry gate |
| `proposal-store.sh` | Queue proposals under `memory/self-mod/proposals/` |
| `rank-candidates.sh` | Utility pre-rank (top-K) |
| `apply-patch.sh` | Apply `content` or `patch_unified` into a suite tree |
| `evaluate-proposal.sh` | Sandbox copy + regression + utility + thresholds |
| `deploy-proposal.sh` | RWLock + divergence + live apply + backup |
| `rollback.sh` | Restore backups + LKG snapshot |
| `monitor.sh` | Post-deploy metrics; auto-rollback on breach |
| `run-pipeline.sh` | End-to-end orchestrator |

## Proposal schema (minimal)

```json
{
  "proposal_id": "prop_example",
  "module": "hippocampus-memory",
  "target_paths": ["skills/hippocampus-memory/scripts/example.sh"],
  "content": "#!/bin/bash\necho ok\n",
  "estimated_components": {
    "task_success": 0.8,
    "resource_cost": 0.2,
    "error_rate": 0.1,
    "regression_penalty": 0.0
  }
}
```

## Verify

```bash
bash tests/run_phase3_harness.sh
```
