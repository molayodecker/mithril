# Fly.io deployment bootstrap

Mithril runs on Fly.io. The physical database migration to Fly Managed Postgres (MPG) is a separate cutover from deploying Phoenix.

## Initial topology

```text
Clients
   |
   v
api.tryinstaclean.com
   |
   v
Mithril / Phoenix on Fly.io (lhr)
   |
   +-- DATABASE_BACKEND=fly ----> Fly Managed Postgres (instaclean-mithril-pg)
   |
   +-- DATABASE_BACKEND=supabase -> Existing Supabase PostgreSQL
```

`DATABASE_BACKEND` is the switch. Default production value is `fly` in `fly.toml`. Keep both connection strings as secrets. Roll back without a code change:

```bash
fly secrets set DATABASE_BACKEND=supabase -a instaclean-mithril
fly secrets unset DATABASE_BACKEND -a instaclean-mithril
```

The second command returns to the `fly.toml` default (`fly`).

Refresh Fly from live Supabase without changing the flag:

```bash
bash scripts/db_sync_from_live.sh
```

The underlying Fly hostname remains available as `instaclean-mithril.fly.dev`, but production clients should use `api.tryinstaclean.com` once DNS and TLS are configured.

In parallel, create a Fly MPG cluster for restore rehearsal:

```text
Cloudflare R2 backup
   |
   v
Fly Managed Postgres rehearsal/target cluster
```

Do **not** attach the MPG cluster to the Mithril app until a restored database has passed parity and migration verification.

## Why London

Instaclean's primary market is Ghana. Fly currently runs application Machines in Johannesburg, but Managed Postgres is not available there. London (`lhr`) supports MPG and keeps Phoenix and PostgreSQL in the same Fly region. Measure real user and database latency before adding additional application regions.

## 1. Authenticate with Fly

Install `flyctl` and authenticate:

```bash
fly auth login
```

## 2. Create the Mithril Fly app

The committed `fly.toml` uses:

```text
instaclean-mithril
```

Create the app:

```bash
fly apps create instaclean-mithril
```

If that globally unique app name is unavailable, choose another name and update `app` in `fly.toml`.

## 3. Set production secrets

Mithril currently requires `SECRET_KEY_BASE` plus the database URLs selected by `DATABASE_BACKEND`. JWT login uses `AUTH_JWT_SECRET` when set, otherwise `SECRET_KEY_BASE`. Phone OTP needs `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_PHONE_NUMBER`. Google/Facebook need `GOOGLE_CLIENT_IDS` and `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET`.

Generate a Phoenix secret locally:

```bash
mix phx.gen.secret
```

Set it on Fly:

```bash
fly secrets set SECRET_KEY_BASE='<generated-secret>' -a instaclean-mithril
```

Keep the current Supabase URL as a rollback secret, and attach Fly MPG to a separate variable so the original `DATABASE_URL` stays intact:

```bash
fly secrets set SUPABASE_DATABASE_URL='<current-supabase-postgres-url>' -a instaclean-mithril
fly mpg attach <cluster-id> -a instaclean-mithril -d fly-db -u fly-user --variable-name FLY_DATABASE_URL
```

`DATABASE_BACKEND=fly` in `fly.toml` makes Mithril use `FLY_DATABASE_URL`. `DATABASE_URL` may remain the Supabase URL for older images and as a supabase-backend fallback.

Never commit these values to git.

## 4. Configure the production API domain

Attach the hostname to the Fly app:

```bash
fly certs add api.tryinstaclean.com -a instaclean-mithril
fly certs setup api.tryinstaclean.com -a instaclean-mithril
```

Use the DNS records printed by Fly. For a subdomain, a CNAME is usually the simplest choice. If DNS is hosted on Cloudflare, use DNS-only while Fly issues the certificate, or, if keeping the Cloudflare proxy enabled, also configure the `_fly-ownership` TXT record shown by `fly certs setup` and use Cloudflare SSL/TLS mode `Full (strict)`.

Check validation status with:

```bash
fly certs check api.tryinstaclean.com -a instaclean-mithril
```

Do not remove the default `instaclean-mithril.fly.dev` hostname; it remains a useful direct Fly fallback.

## 5. Deploy Mithril

```bash
fly deploy -a instaclean-mithril
```

Verify liveness and readiness through the production hostname:

```bash
fly status -a instaclean-mithril
curl https://api.tryinstaclean.com/health
curl https://api.tryinstaclean.com/ready
```

Expected responses:

```json
{ "service": "mithril", "status": "ok" }
```

```json
{
  "service": "mithril",
  "status": "ready",
  "database": "ok",
  "database_backend": "fly"
}
```

`/health` is a lightweight liveness endpoint and does not touch PostgreSQL. `/ready` performs a bounded `SELECT 1` against the configured database and returns HTTP 503 when PostgreSQL is unavailable.

Fly's service-level HTTP check calls `/ready` every 15 seconds. Because service checks control routing, a Machine that cannot reach the database is removed from request routing until readiness recovers. A failed readiness check does not itself restart or stop the Machine.

Live Machine and request telemetry: [instaclean-mithril monitoring](https://fly.io/apps/instaclean-mithril/monitoring).

## 6. Create Fly Managed Postgres

Create PostgreSQL 17 with PostGIS enabled from the start:

```bash
fly mpg create \
  --name instaclean-mithril-pg \
  --region lhr \
  --plan Basic \
  --volume-size 10 \
  --pg-major-version 17 \
  --enable-postgis-support
```

`Basic` and 10 GB are appropriate for the initial restore rehearsal. Re-evaluate CPU, memory, storage, HA, and production sizing before the final database cutover.

Record the cluster ID returned by Fly.

## 7. Attach MPG as `FLY_DATABASE_URL`, not `DATABASE_URL`

Attach with an explicit variable name so the Supabase `DATABASE_URL` is not overwritten:

```bash
fly mpg attach <cluster-id> -a instaclean-mithril -d fly-db -u fly-user --variable-name FLY_DATABASE_URL
```

Do not run `fly mpg attach` without `--variable-name`; the default would replace `DATABASE_URL` and remove the Supabase rollback secret.

For dump/restore work, use Fly's direct connection/proxy rather than the application URL when PostgreSQL tooling requires it.

## 8. Refresh Fly from live Supabase

Keep copying live production onto Fly while both backends exist. See [`docs/migration/production-shadow-sync.md`](../migration/production-shadow-sync.md):

```bash
export SOURCE_DATABASE_URL='postgresql://...'   # session/direct, port 5432
export TARGET_DATABASE_URL='postgresql://...'   # Fly MPG via fly mpg proxy
export CONFIRM_SHADOW_RESTORE=YES
bash scripts/db_sync_from_live.sh
```

Cloudflare R2 remains a disaster-recovery archive, not the normal shadow-sync source. A verified R2 backup from `instaclean-production` looks like:

```text
latest.json
YYYY-MM-DD/<run-id>/full.dump
YYYY-MM-DD/<run-id>/manifest.json
YYYY-MM-DD/<run-id>/checksums.sha256
```

The archive contains production row data, including the Supabase auth schema, but it must not be restored blindly because the current database contains Supabase-specific extensions, roles, policies, functions, and triggers. Prefer `db_sync_from_live.sh` unless you are rehearsing disaster recovery from R2.

## Release migrations

There is intentionally no Fly `release_command` for Ecto migrations yet.

Direct Phase 1 tables are owned by Mithril and applied explicitly:

```bash
export TARGET_DATABASE_URL='postgresql://...@localhost:16380/fly-db'
export CONFIRM_DIRECT_SCHEMA=YES
bash scripts/apply_direct_schema.sh
```

The SQL lives at `priv/repo/sql/direct/20260903170000_direct_phase1.sql`, copied from `molayodecker/instaclean-schema#98` without Supabase RLS/RPCs.

Mithril login tables are also applied explicitly, then existing bcrypt hashes can be copied from live Supabase:

```bash
export TARGET_DATABASE_URL='postgresql://...@localhost:16380/fly-db'
export CONFIRM_AUTH_SCHEMA=YES
bash scripts/apply_auth_schema.sh

export SOURCE_DATABASE_URL='postgresql://...'   # live Supabase session/direct
export CONFIRM_AUTH_IMPORT=YES
bash scripts/import_auth_passwords.sh
```

A later `db_sync_from_live.sh` overwrite drops public tables, including Mithril auth. Re-apply the auth schema and re-import hashes after any full shadow restore.

During coexistence, do not run `mix ecto.migrate` automatically on every Mithril deploy. That could mutate the live Supabase database before Mithril owns the rest of the schema.

## Runtime sizing

The initial Fly Machine is intentionally modest:

```text
1 shared CPU
512 MB RAM
minimum 1 running Machine in lhr
```

Scale based on observed memory, request latency, queue depth, database connections, and traffic rather than guessing up front.
