# social-memory

Relationships and theory of mind for AI agents. See `SKILL.md` for the full reference.

```bash
./install.sh --with-cron
./scripts/upsert-relationship.sh --id dyther --name "Dyther" --type human
./scripts/log-interaction.sh --id dyther --summary "..." --trust-delta 0.05
./scripts/get-relationship.sh --id dyther
./scripts/list-relationships.sh
```
