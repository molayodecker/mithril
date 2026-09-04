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
   v
Existing Supabase PostgreSQL
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

Mithril currently requires both `SECRET_KEY_BASE` and `DATABASE_URL` in production.

Generate a Phoenix secret locally:

```bash
mix phx.gen.secret
```

Set it on Fly:

```bash
fly secrets set SECRET_KEY_BASE='<generated-secret>' -a instaclean-mithril
```

For the first deployment, point Mithril at the existing Supabase PostgreSQL database rather than Fly MPG:

```bash
fly secrets set DATABASE_URL='<current-supabase-postgres-url>' -a instaclean-mithril
```

Never commit either value to git.

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
{"service":"mithril","status":"ok"}
```

```json
{"service":"mithril","status":"ready","database":"ok"}
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

## 7. Do not attach MPG to Mithril yet

Fly can attach MPG with:

```bash
fly mpg attach <cluster-id> -a instaclean-mithril
```

That command sets the app's `DATABASE_URL` to the MPG pooled/PgBouncer connection. **Do not run it yet.** The current production application database remains Supabase while we prepare and verify the Fly restore.

For restore/import work, use Fly's direct database connection/proxy instead of the pooled application URL when required by PostgreSQL tooling.

## 8. Rehearse the database migration

Use the latest verified R2 backup produced by `instaclean-production`:

```text
latest.json
YYYY-MM-DD/<run-id>/full.dump
YYYY-MM-DD/<run-id>/manifest.json
YYYY-MM-DD/<run-id>/checksums.sha256
```

The archive contains production row data, including the Supabase auth schema, but it must not be restored blindly because the current database contains Supabase-specific extensions, roles, policies, functions, and triggers.

The rehearsal sequence is:

1. pull the latest verified backup from R2
2. inspect `full.dump` with `pg_restore --list`
3. prepare a Fly-compatible restore list/schema transformation
4. restore into the MPG rehearsal database
5. validate PostGIS, row counts, identities, bookings, pricing, wallets, payments, availability, functions, triggers, and security behavior
6. run Mithril parity tests against the Fly database
7. only after parity passes, plan the live database cutover

## Release migrations

There is intentionally no Fly `release_command` for Ecto migrations yet.

During coexistence, Supabase remains the canonical schema owner. Automatically running `mix ecto.migrate` during every Mithril deploy could mutate the live Supabase database before Mithril owns that schema. Add a controlled release migration command only after the relevant DDL has been moved under Mithril/Ecto ownership.

## Runtime sizing

The initial Fly Machine is intentionally modest:

```text
1 shared CPU
512 MB RAM
minimum 1 running Machine in lhr
```

Scale based on observed memory, request latency, queue depth, database connections, and traffic rather than guessing up front.
