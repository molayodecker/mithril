# Cloudflare R2 database backup archive

## Purpose

Cloudflare R2 bucket `insta-production` is an external archive for Instaclean PostgreSQL backup artifacts. It is not the live application database and Mithril should not treat it as a transactional datastore.

Known backup set:

```text
2026-05-20/26137003002/schema.sql.gz
2026-05-20/26137003002/functions_triggers.sql.gz
```

The live migration target for PostgreSQL is Fly Managed Postgres.

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

## What the known files represent

Based on their names, the known artifacts appear to preserve database structure and stored database logic:

- `schema.sql.gz`: tables, schemas, types, indexes, constraints, policies, extensions, or related DDL depending on how the backup job was produced.
- `functions_triggers.sql.gz`: PostgreSQL functions and triggers or other extracted procedural database logic.

Do not assume these two files contain production table rows. Before using an R2 backup set as a full migration or disaster-recovery source, verify that the same backup set also contains a data/full dump and inspect the backup manifest or generation script.

Production rows that must be accounted for include customers, cleaners, bookings, services, payments, schedules, wallet/payout state, messages, and any other operational tables.

## Backup verification

For every backup set used for migration or recovery:

1. Record the backup timestamp and source database version.
2. Verify all expected artifacts are present.
3. Verify compressed files can be decompressed successfully.
4. Inspect SQL headers and contents before executing them.
5. Confirm whether `schema.sql.gz` contains schema-only DDL or includes data statements.
6. Locate and verify a data/full dump if table rows are stored separately.
7. Record checksums and object sizes when possible.
8. Test the complete restore into an isolated PostgreSQL database.
9. Compare table counts, functions, triggers, constraints, policies, and representative queries with the source.

The dated `2026-05-20` backup is useful for restore testing, but it must not be used as the final production cutover snapshot in September 2026 unless the missing changes since that date are intentionally accounted for. Use a fresh backup or direct database dump for the final migration.

## Credentials

If an automated restore/rehearsal job needs to fetch R2 objects, use a read-only API token scoped to `insta-production`.

Never commit the Access Key ID or Secret Access Key. Configure credentials as Fly secrets or CI secrets only when a restore job actually needs them.

```bash
fly secrets set \
  R2_ACCESS_KEY_ID='<access-key-id>' \
  R2_SECRET_ACCESS_KEY='<secret-access-key>'
```

Non-secret configuration:

```text
R2_BUCKET=insta-production
R2_ENDPOINT=https://90a7b11a99d10b148259091ea6b4207c.r2.cloudflarestorage.com
R2_REGION=auto
```

The normal Mithril web process does not need R2 backup credentials unless database backup/restore operations are intentionally implemented inside that runtime. Prefer a separate release task, CI job, or operator-run restore process instead of granting the application permanent backup-vault access.

## Restore boundary

R2 should remain independent of the Fly Managed Postgres automatic backups. This gives Instaclean two different recovery paths:

```text
Supabase/current PostgreSQL
        │
        ├── external logical backup ──> Cloudflare R2
        │
        └── migration/cutover ────────> Fly Managed Postgres
                                          │
                                          └── Fly managed backups / recovery
```

Do not copy database backups onto a Fly Machine root filesystem for permanent storage. Download them only for a controlled restore operation and discard temporary local copies afterward.
