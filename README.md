# Mithril

Mithril is the Phoenix/Elixir backend for Instaclean.

It will incrementally replace application behavior currently implemented in `instaclean-schema` / Supabase while continuing to use PostgreSQL as the system of record during the migration.

## Baseline

- Legacy source: `molayodecker/instaclean-schema`
- Migration baseline commit: `d13b81e5ce5d5ede6a8884394791a5e274609095`
- Phoenix: `~> 1.8.13`
- Elixir: `~> 1.20`
- Ecto SQL: `~> 3.14`
- Repository visibility: private
- Runtime target: Fly.io
- Database target: Fly Managed Postgres
- External database backup archive: Cloudflare R2 bucket `insta-production`

The old repository and Supabase production database remain the source of truth until each capability is migrated and verified. Do not repoint the web/mobile `supabase` submodules to this repository yet.

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

## Production database

The target production database is Fly Managed Postgres. During migration, Mithril can continue to connect to the current Supabase-hosted PostgreSQL database until parity and cutover are complete.

Cloudflare R2 bucket `insta-production` is an external backup archive, not the live application database. Known backup artifacts include:

```text
2026-05-20/26137003002/schema.sql.gz
2026-05-20/26137003002/functions_triggers.sql.gz
```

These artifacts are useful for reconstructing database structure and stored logic. Before treating an R2 backup set as a full disaster-recovery or migration source, verify that it also contains a data/full dump for production rows.

See:

- [`docs/infrastructure/cloudflare-r2.md`](docs/infrastructure/cloudflare-r2.md)
- [`docs/infrastructure/fly-managed-postgres.md`](docs/infrastructure/fly-managed-postgres.md)

## Migration strategy

Mithril uses a strangler migration rather than a big-bang replacement.

1. Connect Phoenix/Ecto to the existing Supabase PostgreSQL database.
2. Add read models for existing tables without changing production behavior.
3. Move one vertical slice at a time from Edge Functions/RPCs into Phoenix contexts.
4. Route selected traffic to Mithril behind feature flags.
5. Move scheduled/background work after synchronous flows are stable.
6. Provision and validate a Fly Managed Postgres target with required extensions, including PostGIS.
7. Perform a rehearsal restore/import and compare schema, row counts, functions, triggers, constraints, and critical queries.
8. Cut production database traffic to Fly Managed Postgres only after a fresh data sync and rollback plan are ready.
9. Replace Supabase realtime/auth/storage dependencies separately where appropriate.
10. Retire Supabase-specific code only after parity, observability, rollback, and traffic verification.

See [`docs/migration/supabase-to-phoenix.md`](docs/migration/supabase-to-phoenix.md) for the application cutover plan.

## Safety

Mithril is private, but secrets still never belong in git. Never commit credentials, service-role keys, database passwords, webhook secrets, private operational data, or production-only secret values.
