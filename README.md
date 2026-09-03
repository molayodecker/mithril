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
- Production object storage: Cloudflare R2 bucket `insta-production`
- Runtime target: Fly.io

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

## Production storage

Mithril uses Cloudflare R2 for production object storage while PostgreSQL remains the transactional source of truth for bookings, users, pricing, payments, and other relational state.

R2 is accessed from Fly.io through its S3-compatible endpoint. Configure credentials as Fly secrets, never in git.

Required runtime values:

```text
R2_BUCKET=insta-production
R2_ENDPOINT=https://90a7b11a99d10b148259091ea6b4207c.r2.cloudflarestorage.com
R2_ACCESS_KEY_ID=<secret>
R2_SECRET_ACCESS_KEY=<secret>
R2_REGION=auto
```

See [`docs/infrastructure/cloudflare-r2.md`](docs/infrastructure/cloudflare-r2.md).

## Migration strategy

Mithril uses a strangler migration rather than a big-bang replacement.

1. Connect Phoenix/Ecto to the existing PostgreSQL database.
2. Add read models for existing tables without changing production behavior.
3. Move one vertical slice at a time from Edge Functions/RPCs into Phoenix contexts.
4. Route selected traffic to Mithril behind feature flags.
5. Move scheduled/background work after synchronous flows are stable.
6. Replace Supabase Storage consumers with the R2 adapter where appropriate.
7. Replace Supabase realtime with Phoenix PubSub/Channels where appropriate.
8. Retire Supabase-specific code only after parity, observability, rollback, and traffic verification.

See [`docs/migration/supabase-to-phoenix.md`](docs/migration/supabase-to-phoenix.md) for the cutover plan.

## Safety

Mithril is private, but secrets still never belong in git. Never commit credentials, service-role keys, database passwords, webhook secrets, private operational data, or production-only secret values.
