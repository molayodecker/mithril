# Cloudflare R2 database backup archive

## Purpose

Cloudflare R2 bucket `insta-production` is an independent PostgreSQL backup archive for Instaclean. It is not the live database and is not Mithril's application object-storage layer.

The target production database for Mithril is Fly Managed Postgres.

Known backup prefix:

```text
2026-05-20/26137003002/
```

Known artifacts:

```text
schema.sql.gz
functions_triggers.sql.gz
```

A direct inspection of the uploaded copies confirms that these two artifacts contain schema/database logic but **no table row data**. See [`../migration/r2-backup-inspection-2026-05-20.md`](../migration/r2-backup-inspection-2026-05-20.md) for the detailed audit.

## R2 endpoint

Cloudflare account endpoint:

```text
https://90a7b11a99d10b148259091ea6b4207c.r2.cloudflarestorage.com
```

Bucket:

```text
insta-production
```

Region for S3-compatible clients:

```text
auto
```

## Credentials

R2 credentials are backup/recovery credentials, not normal Mithril application runtime credentials.

Prefer a bucket-scoped token with the minimum permissions needed by the backup or restore job. Never commit the Access Key ID or Secret Access Key.

If a Fly release command or one-off Machine needs to retrieve a backup, inject the credentials only for that job through Fly secrets or another temporary secret mechanism.

Do not make R2 credentials available to the normal web process unless there is a concrete runtime requirement.

## Role in the migration

The May 20 artifacts are useful for:

- migration rehearsal
- schema inventory
- discovering Supabase-specific dependencies
- extracting Instaclean-owned functions and triggers
- validating a restore transformation pipeline

They are **not** a complete production database restore source because neither file contains `COPY` or `INSERT INTO` row data.

A final production migration must use a fresh complete data dump from the live Supabase Postgres database, or another verified synchronization mechanism that includes all production rows.

## Fly Managed Postgres compatibility

Do not restore the May SQL files unchanged into Fly MPG.

The schema requests these extensions:

```text
pg_cron
pg_net
btree_gist
pg_stat_statements
pgcrypto
postgis
supabase_vault
uuid-ossp
```

PostGIS should be provisioned through Fly MPG. Supabase-specific or unsupported third-party extensions such as `pg_net`, `pg_cron`, and `supabase_vault` need a replacement strategy.

The schema also depends heavily on Supabase Auth constructs including `auth.users`, `auth.uid()`, `anon`, `authenticated`, and `service_role`. Those dependencies must be decoupled or intentionally reproduced before the public schema can live independently on Fly.

The supplemental functions/triggers dump also captures extension-owned functions, including a large PostGIS function surface. Do not replay all of those functions into the target. Install the extension normally and restore only Instaclean-owned functions that remain necessary.

## Backup handling

R2 remains off-platform disaster-recovery storage even after the live database moves to Fly MPG.

Recommended future backup shape:

```text
YYYY-MM-DD/<backup-id>/
  manifest.json
  schema.sql.gz
  data.dump or full.dump
  functions_triggers.sql.gz   # only if still useful
  checksums.sha256
```

The manifest should record at least:

- source database/provider
- PostgreSQL major version
- dump tool version
- dump type/format
- included schemas
- whether data rows are included
- creation timestamp
- source migration/commit marker where available

A backup is not considered production-restorable until an automated or rehearsed restore verifies both structure and row data.

## Production cutover principle

The May 20 backup is too old for a September 2026 production cutover even if it contained rows. Use it for rehearsal and compatibility work only.

At final cutover, take a fresh live dump or perform a controlled synchronization, restore it into Fly MPG, verify it, and only then change Mithril's `DATABASE_URL`.