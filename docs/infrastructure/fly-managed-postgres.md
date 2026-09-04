# Fly Managed Postgres

## Bootstrap the Fly resources

Mithril includes an idempotent bootstrap script for the initial Fly resources:

```bash
fly auth login
bash scripts/bootstrap_fly.sh
```

By default it creates, if missing:

- Fly app: `instaclean-mithril`
- Managed Postgres: `instaclean-mithril-pg`
- region: `lhr` (London)
- plan: `Basic`
- storage: 10 GB
- PostgreSQL 17
- PostGIS enabled at provisioning

If the resources already exist, the script leaves them in place. It intentionally does **not** attach Managed Postgres to the app, because attaching would replace the application's `DATABASE_URL` before the R2 restore and parity checks are complete.

Optional overrides:

```bash
FLY_ORG=my-org \
FLY_APP_NAME=instaclean-mithril \
FLY_MPG_NAME=instaclean-mithril-pg \
FLY_REGION=lhr \
FLY_MPG_PLAN=Basic \
FLY_MPG_VOLUME_SIZE=10 \
FLY_PG_MAJOR_VERSION=17 \
bash scripts/bootstrap_fly.sh
```

Creating a Managed Postgres cluster is a billable Fly.io resource. The `Basic` plan is the initial rehearsal/small-production baseline; resize or replace it after measuring the restored workload.

## Target architecture

Fly Managed Postgres is the target production database for Mithril.

During the application migration, Mithril may continue to connect to the existing Supabase-hosted PostgreSQL database. Moving application behavior into Phoenix and moving the physical PostgreSQL cluster are separate cutovers and should not happen at the same time unless necessary.

```text
Phase 1
Clients -> Mithril on Fly.io -> Supabase PostgreSQL

Phase 2
Clients -> Mithril on Fly.io -> Fly Managed Postgres
```

Cloudflare R2 remains an independent logical-backup archive and is not in the normal request path.

## Required capabilities

Instaclean currently relies on PostgreSQL features beyond basic tables and indexes. Before migration, inventory all installed extensions and server-side behavior.

At minimum, validate:

- PostGIS and geospatial types/functions
- UUID generation functions
- extensions referenced by migrations
- custom enum/types
- RLS policies
- triggers
- stored functions/RPCs
- scheduled jobs currently implemented with `pg_cron`
- database roles and grants
- auth-schema dependencies such as `auth.uid()`

Fly Managed Postgres supports PostGIS when enabled for the cluster. Do not restore production DDL until required extensions have been enabled.

## Migration source priority

For the final production migration, prefer a fresh direct logical dump from the current production PostgreSQL database because it captures current rows and schema in one controlled migration window.

The Cloudflare R2 backup archive is useful for:

- validating disaster recovery
- rehearsing schema/function restoration
- comparing historical schema state
- recovering when the primary source is unavailable

Known R2 artifacts from `2026-05-20/26137003002/` are not recent enough to serve as the September 2026 production cutover snapshot without an additional current data synchronization.

## Rehearsal migration

Before production cutover:

1. Provision a non-production Fly Managed Postgres cluster using the intended PostgreSQL major version.
2. Enable PostGIS and every supported extension required by Instaclean.
3. Create an isolated target database.
4. Restore a representative backup or fresh dump.
5. Capture and resolve restore errors rather than suppressing them blindly.
6. Compare schema objects and row counts.
7. Run Mithril parity tests against the restored database.
8. Exercise booking availability, pricing, assignment, payment state, and cancellation flows against the target.
9. Confirm indexes and representative query plans are acceptable.
10. Measure the time required for the complete import and verification procedure.

## Production cutover

A safe final sequence is:

1. Announce or enter a short write-control window if needed.
2. Create a fresh logical dump from the production source.
3. Restore/import it into the prepared Fly Managed Postgres database.
4. Run verification checks and critical smoke tests.
5. Point Mithril `DATABASE_URL` at Fly Managed Postgres.
6. Keep web/mobile routing changes independently reversible.
7. Monitor errors, latency, payment flows, availability, and booking state transitions.
8. Keep the Supabase database intact and read-only/standby for a defined rollback period.
9. Remove the old database only after the rollback window closes and a fresh Fly backup has been verified.

For simple databases, Fly documents standard `pg_dump` and `psql` import through `fly mpg proxy`. Instaclean is not a simple schema, so use the same primitives with explicit extension, role, RLS, and stored-function verification.

## What not to migrate blindly

Some Supabase-owned implementation details should not simply be restored and assumed to work on Fly:

- `auth.*` assumptions
- `storage.*` assumptions
- Supabase-specific grants or service roles
- Edge Function behavior
- realtime publication/configuration
- Vault/secrets integrations
- provider-specific cron behavior

Where Mithril replaces those responsibilities, preserve the business rule rather than the provider-specific mechanism.

## Runtime configuration

Production Mithril uses `DATABASE_URL`.

Keep database credentials in Fly secrets. Do not store the production connection string in git.

The Mithril application should use a dedicated least-privilege database role. Administrative restore credentials must remain separate from normal runtime credentials.
