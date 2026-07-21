# prefrontal-cortex-memory

Executive function: goals, impulse control, and arbitration across the brain suite. See `SKILL.md` for the full reference.

```bash
./install.sh --with-cron
./scripts/goals.sh add --description "Ship the v2 dashboard" --priority 0.8
./scripts/inhibitions.sh add --pattern "interrupt mid-task" --reason "breaks flow"
./scripts/decide.sh --context heartbeat --options '[{"id":"a","label":"Option A","weight":1.0}]'
./scripts/get-state.sh
```

Install alongside `heartbeat-memory` for real decision-making instead of weighted-random choice.
