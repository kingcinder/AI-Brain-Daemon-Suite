# Self-Modification Pipeline — Immutable Core Protection

Phase 3 pipeline implementation lives in this directory. **This tree must never
be a proposal target** (`immutable-paths.list` + `check-target.sh` enforce it).

## Hard rule

The following paths must **never** be targets of automated patches:

- `skills/prefrontal-cortex-memory/scripts/decide.sh`
- `core/locks/rwlock.sh`
- `core/locks/pid-lock.sh`
- `core/concurrency/semaphore.sh`
- `core/sandbox/sandbox-run.sh`
- `core/executive-load/calc-executive-load.sh`
- `core/self-mod/**` (this pipeline)

Only modules with a valid `capability-manifest.json` (`immutable: false`) may be proposed for modification.

Machine-readable list: `immutable-paths.list`  
Gate: `check-target.sh`

## Canonical pipeline (V4.0) — `run-pipeline.sh`

1. Baseline snapshot  
2. Generate / ingest proposals (isolated context, no write permissions)  
3. Rank by Utility Function (`rank-candidates.sh`)  
4. Sandbox execution (eval suite copy + apply-patch)  
5. Regression tests + benchmarks  
6. Utility calculation + Rollback check (`thresholds.json`)  
7. Accept / reject (asymmetric graduation)  
8. Deploy under RWLock + divergence check (`deploy-proposal.sh`)  
9. Continuous monitoring (`monitor.sh` / daemon job `self_mod_monitor`)  
10. Auto-rollback if thresholds breached (`rollback.sh`)  

### Rollback thresholds

- Task success / benchmark decrease > 3%  
- Latency increase > 20%  
- Memory / KV cache increase > 15%  
- Any regression test failure  

Rollback = file restore from `memory/self-mod/backups/<id>/` + LKG snapshot
(`snapshot.sh restore`); `git` best-effort when a `.git` repo exists.
