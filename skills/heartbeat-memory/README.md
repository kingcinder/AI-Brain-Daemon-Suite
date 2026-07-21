# heartbeat-memory

Autonomous initiative on a 30-minute timer. See `SKILL.md` for the full reference.

```bash
./install.sh --with-cron
./scripts/projects.sh add --title "Finish the report" --type unfinished
./scripts/beat.sh
./scripts/log-action.sh --action project_work --note "Drafted section 2"
./scripts/get-state.sh
```

Pairs with `prefrontal-cortex-memory` for real decision-making instead of weighted-random choice.
