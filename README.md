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
- Target production database: Fly Managed Postgres
- Off-platform database backup archive: Cloudflare R2 bucket `insta-production`
- Operating baseline: [12-Factor](docs/architecture/12-factor.md)

The old repository remains the production source of truth until each capability is migrated and verified. Do not repoint the web/mobile `supabase` submodules to this repository yet.

## Operating model

Mithril is designed as a stateless, disposable Phoenix service. Deploy-specific configuration is supplied at runtime, backing services are replaceable resources, and durable business state never depends on one Fly Machine or one BEAM process.

Key rules:

- runtime configuration comes from environment variables and Fly secrets
- the production Docker image contains code and dependencies, never secrets
- PostgreSQL is the durable source of truth for transactional state
- Fly Machine disk and BEAM memory hold only temporary/reconstructable state
- external side effects must be idempotent
- durable background work must use a durable queue when introduced
- logs go to stdout/stderr
- database migration/cutover is separate from ordinary app boot

See [`docs/architecture/12-factor.md`](docs/architecture/12-factor.md) for the full review checklist and Instaclean-specific guardrails.

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

`.env.example` documents the runtime configuration contract. Mithril does not require that file at runtime and does not automatically load it; it is an example only.

### Phone OTP test numbers

Phone login normally sends a Twilio SMS. For local development, App Store review, or other cases where a real SMS is not wanted, set `AUTH_TEST_PHONES` to comma-separated `phone:otp` pairs. Listed numbers skip Twilio and accept the paired code, the same as Supabase Auth test phone numbers.

```bash
AUTH_TEST_PHONES=+15555550100:123456,+233555000000:000000
```

```bash
curl -X POST http://localhost:4000/auth/otp \
  -H 'content-type: application/json' \
  -d '{"phone":"+233555000000","should_create_user":true}'

curl -X POST http://localhost:4000/auth/otp/verify \
  -H 'content-type: application/json' \
  -d '{"phone":"+233555000000","token":"000000"}'
```

Ghana local numbers are accepted (`0555000000` matches `+233555000000`). Unlisted numbers still require Twilio. Treat the OTPs like passwords.

## Database and backups

Mithril's target live database is Fly Managed Postgres. PostgreSQL remains the transactional source of truth for bookings, users, pricing, payments, wallets, availability, and other relational state.

Cloudflare R2 bucket `insta-production` is an independent database backup archive. It is not the live database and is not the application's primary object store.

The known May 20, 2026 backup contains:

```text
2026-05-20/26137003002/schema.sql.gz
2026-05-20/26137003002/functions_triggers.sql.gz
```

Direct inspection confirms these files contain schema/functions/triggers but no table row data, so they are useful for migration rehearsal and compatibility analysis but cannot restore production records by themselves.

See:

- [`docs/infrastructure/cloudflare-r2.md`](docs/infrastructure/cloudflare-r2.md)
- [`docs/infrastructure/fly-managed-postgres.md`](docs/infrastructure/fly-managed-postgres.md)
- [`docs/migration/r2-backup-inspection-2026-05-20.md`](docs/migration/r2-backup-inspection-2026-05-20.md)

## Migration strategy

Mithril uses a strangler migration rather than a big-bang replacement.

1. Run Phoenix against the existing Supabase PostgreSQL database while application behavior moves into Mithril.
2. Add read models for existing tables without changing production behavior.
3. Move one vertical slice at a time from Edge Functions/RPCs into Phoenix contexts.
4. Route selected traffic to Mithril behind feature flags.
5. Move scheduled/background work after synchronous flows are stable.
6. Decouple public-schema authorization and foreign keys from Supabase Auth-specific database constructs.
7. Rehearse restoring a transformed schema into Fly Managed Postgres.
8. At database cutover, take a fresh complete dump/synchronization from live Supabase Postgres and restore it into Fly MPG.
9. Replace Supabase realtime with Phoenix PubSub/Channels where appropriate.
10. Retire Supabase-specific code only after parity, observability, rollback, and traffic verification.

See [`docs/migration/supabase-to-phoenix.md`](docs/migration/supabase-to-phoenix.md) for the broader cutover plan.

## Safety

Mithril is private, but secrets still never belong in git. Never commit credentials, service-role keys, database passwords, webhook secrets, private operational data, or production-only secret values.
