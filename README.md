# Mithril

Mithril is the Phoenix/Elixir backend for Instaclean.

It will incrementally replace application behavior currently implemented in `instaclean-schema` / Supabase while continuing to use PostgreSQL as the system of record during the migration.

## Baseline

- Legacy source: `molayodecker/instaclean-schema`
- Migration baseline commit: `d13b81e5ce5d5ede6a8884394791a5e274609095`
- Phoenix: `~> 1.8.13`
- Elixir: `~> 1.20`
- Ecto SQL: `~> 3.14`

The old repository remains the production source of truth until each capability is migrated and verified. Do not repoint the web/mobile `supabase` submodules to this repository yet.

## Local development

```bash
mix deps.get
mix ecto.create
mix phx.server
```

Health check:

```bash
curl http://localhost:4000/health
```

Expected response:

```json
{"service":"mithril","status":"ok"}
```

To connect Mithril to an existing PostgreSQL database, set `DATABASE_URL`.

```bash
DATABASE_URL=ecto://user:password@host:5432/database mix phx.server
```

## Migration strategy

Mithril uses a strangler migration rather than copying the private Supabase repository into this public repository.

1. Connect Phoenix/Ecto to the existing PostgreSQL database.
2. Add read models for existing tables without changing production behavior.
3. Move one vertical slice at a time from Edge Functions/RPCs into Phoenix contexts.
4. Route selected traffic to Mithril behind feature flags.
5. Move scheduled/background work after synchronous flows are stable.
6. Replace Supabase realtime with Phoenix PubSub/Channels where appropriate.
7. Retire Supabase-specific code only after parity, observability, rollback, and traffic verification.

See [`docs/migration/supabase-to-phoenix.md`](docs/migration/supabase-to-phoenix.md) for the cutover plan.

## Safety

`instaclean-schema` is private while Mithril is public. Never commit credentials, service-role keys, database passwords, webhook secrets, private operational data, or production-only configuration here.
