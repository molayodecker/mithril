# Production → Mithril shadow database sync

This runbook creates a **read-only migration rehearsal copy** of the current Instaclean production database in Mithril's dedicated Fly Managed Postgres target.

The source remains authoritative throughout this process. Do not point customer traffic or production writes at the shadow database merely because the restore succeeds.

## Safety model

- Production is read only during inventory and snapshot creation.
- The snapshot covers the entire `public` schema rather than a handwritten table list.
- Supabase-owned auth secrets are not copied.
- A sanitized `auth.users` identity projection is created only to preserve UUID relationships and exercise current trust/parity logic.
- The restore script refuses to run unless `CONFIRM_SHADOW_RESTORE=YES` is set.
- A target URL that looks like Supabase is rejected by default.
- The restore is considered invalid until every public table in the snapshot has matching row counts.

## Prerequisites

Install:

- PostgreSQL client tools (`psql`, `pg_dump`, `pg_restore`)
- Python 3
- `flyctl`

Provision the Mithril Fly resources first:

```bash
bash scripts/bootstrap_fly.sh
```

The intended target is `instaclean-mithril-pg`. The bootstrap intentionally does not attach it to the app.

## 1. Set source credentials locally

Use the direct PostgreSQL connection for the current Instaclean production database.

```bash
export SOURCE_DATABASE_URL='postgresql://...'
```

Never commit this value.

## 2. Inventory the live source

```bash
bash scripts/db_sync_inventory.sh
```

The command writes a private timestamped directory beneath `.artifacts/db-sync/` containing:

- database/server metadata
- every non-system table
- exact row counts for every `public` table
- extension inventory
- public object counts
- public foreign keys that reference non-public schemas
- public functions that reference `auth.*`
- a captured extension creation manifest

This is the authoritative migration inventory. Repository migrations are useful history, but the production PostgreSQL catalog decides what must be migrated.

## 3. Create the shadow snapshot

```bash
bash scripts/db_sync_snapshot.sh
```

The snapshot contains:

- `public.dump`: custom-format dump of the complete `public` schema and data
- `auth_identity_projection.csv`: sanitized identity bridge
- `public_row_counts.csv`: exact source row counts
- `required_extensions.sql`: captured extension inventory for review
- checksums and PostgreSQL client versions

The auth projection intentionally excludes password hashes, refresh/session tokens, recovery tokens, confirmation tokens, MFA secrets, provider identities, and other Supabase Auth secrets.

Treat the entire snapshot directory as production-sensitive data even though auth secrets are excluded.

## 4. Connect to the Fly shadow database

Use Fly's Managed Postgres tooling to obtain a private/proxied PostgreSQL connection for `instaclean-mithril-pg`, then export it locally:

```bash
export TARGET_DATABASE_URL='postgresql://...'
export SNAPSHOT_DIR='.artifacts/db-sync/<timestamp>'
```

Confirm the target is the shadow database, not the current production Supabase database.

## 5. Review extension compatibility

Inspect:

```bash
cat "$SNAPSHOT_DIR/extensions.csv"
cat "$SNAPSHOT_DIR/required_extensions.sql"
```

PostGIS and any extension used by restored public objects must exist on the target. Supabase-specific extensions should not be enabled blindly.

If the captured manifest has been reviewed and is appropriate for the Fly cluster:

```bash
export APPLY_CAPTURED_EXTENSIONS=YES
```

Otherwise enable only the required supported extensions on the target before restore.

## 6. Restore the shadow copy

The following operation is destructive **only to the target database**:

```bash
export CONFIRM_SHADOW_RESTORE=YES
bash scripts/db_sync_restore_shadow.sh
```

The restore script:

1. rejects an identical source/target URL when both are supplied;
2. rejects Supabase-looking targets by default;
3. creates compatibility roles used by existing RLS policies;
4. creates a minimal `auth` compatibility surface;
5. loads the sanitized auth identity projection;
6. restores the complete `public` schema and data with `pg_restore`.

Current public SQL still contains Supabase-era `auth.uid()`/`auth.jwt()` assumptions. The shadow compatibility functions exist for parity/rehearsal only. They are not a replacement authentication architecture.

## 7. Verify table parity

```bash
bash scripts/db_sync_verify.sh
```

Verification compares the restored target against the row counts captured at snapshot time, not against the continuously changing live source.

It fails if:

- a source public table is missing on the target;
- the target has an unexpected public table;
- any public table row count differs;
- the sanitized auth identity count differs.

The detailed result is written to:

```text
$SNAPSHOT_DIR/parity_report.csv
```

## 8. Application parity tests

Only after row-count parity passes:

1. point a non-customer-facing Mithril environment at the shadow database;
2. run `/ready`;
3. run booking parity endpoints against known production IDs;
4. map and compare users/profiles, cleaners, availability, services/pricing, properties, schedule groups, Direct placement data, payments, payouts, messaging, Quick Tasks, promotions, and every other production domain represented in `public`;
5. inventory failures caused by Supabase-specific functions, RLS, triggers, extensions, cron, storage, realtime, or Auth assumptions.

Do not switch writes yet.

## 9. Keeping the shadow current

This first implementation is a point-in-time snapshot. If the migration requires a long coexistence period, choose an incremental strategy only after the full restore is repeatable and verified.

Possible next stage:

```text
Supabase production PostgreSQL
          |
          | CDC / logical replication
          v
Mithril shadow PostgreSQL
          |
          v
Phoenix parity reads
```

Do not introduce two-way replication. During migration there must be one authoritative writer until an explicit cutover.

## 10. Cutover remains separate

A successful shadow sync does not change production routing.

Cutover requires its own checklist for:

- final delta/write-control window
- Phoenix authorization replacing Supabase RLS assumptions
- Auth strategy
- storage/realtime behavior
- RPC/function replacements
- background jobs/cron
- payment and payout idempotency
- rollback
- monitoring and backups

The old Supabase database should remain intact through a defined rollback period after any eventual database cutover.
