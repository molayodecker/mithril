# Production → Mithril Fly database sync

Refresh Fly Managed Postgres from **live Instaclean production (Supabase)**. This is a repeatable point-in-time dump and restore. It does not flip `DATABASE_BACKEND`.

Supabase remains the sync source. Mithril serves whichever backend `DATABASE_BACKEND` selects (`fly` or `supabase`).

## Sync from live production

Use a session-mode or direct PostgreSQL URL for production (port **5432**). Do not use the transaction pooler (port **6543**).

```bash
export SOURCE_DATABASE_URL='postgresql://...'
```

If `SOURCE_DATABASE_URL` is unset, the script will use a local `DATABASE_URL` that starts with `postgresql://`. Confirm that value is production, not the Fly shadow cluster.

Connect to `instaclean-mithril-pg` through Fly's proxy, then:

```bash
fly mpg proxy <cluster-id> -p 16380
export TARGET_DATABASE_URL='postgresql://...@localhost:16380/fly-db'
export CONFIRM_SHADOW_RESTORE=YES
bash scripts/db_sync_from_live.sh
```

That command:

1. snapshots live production (`public` schema, exact row counts, sanitized `auth.users` identities);
2. restores the snapshot into the shadow database;
3. verifies every public table's row count against that snapshot.

Each run writes a new directory under `.artifacts/db-sync/<timestamp>/`. `.artifacts/db-sync/LATEST` points at the most recent live sync. Treat those directories as production-sensitive data.

A previous timestamped directory (for example `20260904T040510Z`) is only a historical rehearsal artifact. Re-run `db_sync_from_live.sh` whenever the shadow copy must match current production.

Cloudflare R2 backups are disaster-recovery archives. They are not this workflow.

## Safety model

- Production remains writable during snapshot creation.
- The data-bearing artifacts are captured from one exported PostgreSQL repeatable-read snapshot, so `public.dump`, exact public row counts, and the sanitized auth identity projection describe the same point in time.
- The snapshot covers the entire `public` schema rather than a handwritten table list.
- Supabase-owned auth secrets are not copied.
- A sanitized `auth.users` identity projection is created only to preserve UUID relationships and exercise current trust/parity logic.
- Supabase's internal role topology is not cloned. Only application-facing shadow roles and their effective public runtime grants are captured for parity.
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

On Fly Managed Postgres, enable supported extensions through `fly mpg` before the first restore (`postgis`, `btree_gist`, `citext`, `pgcrypto`, `uuid-ossp`). Do not apply captured Supabase-only extensions such as `pg_cron`, `pg_net`, or `supabase_vault`. Create application-facing users (`anon`, `authenticated`, `service_role`) with `fly mpg users` if they do not already exist; MPG does not allow `CREATE ROLE` or `GRANT` against those users from `psql`.

## Manual steps

The live sync command calls these scripts in order. Use them directly only when you need to inspect an existing snapshot or re-restore one.

### 1. Inventory the live source

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
- application-facing shadow roles
- reviewed effective runtime grants for those roles
- a captured extension creation manifest

This is the authoritative migration inventory. Repository migrations are useful history, but the production PostgreSQL catalog decides what must be migrated.

Do not run schema migrations concurrently with the production snapshot. Normal application writes are fine because the data-bearing artifacts use one exported repeatable-read snapshot.

### 2. Create the shadow snapshot

```bash
bash scripts/db_sync_snapshot.sh
```

The script opens a read-only repeatable-read transaction, exports its PostgreSQL snapshot ID, and keeps that transaction open while the dump, exact public row counts, and sanitized auth projection are captured from that same snapshot. The keeper transaction is closed immediately afterward so it does not unnecessarily hold back vacuum.

The snapshot contains:

- `public.dump`: custom-format dump of the complete `public` schema and data
- `auth_identity_projection.csv`: sanitized identity bridge from the same point-in-time snapshot
- `public_row_counts.csv`: exact source row counts from the same snapshot
- `public_shadow_roles.txt`: application-facing roles needed for parity
- `public_shadow_grants.sql`: effective public runtime grants for those roles
- `required_extensions.sql`: captured extension inventory for review
- `snapshot_id.txt`: the exported snapshot identifier used for the capture
- checksums and PostgreSQL client versions

The auth projection intentionally excludes password hashes, refresh/session tokens, recovery tokens, confirmation tokens, MFA secrets, provider identities, and other Supabase Auth secrets.

Treat the entire snapshot directory as production-sensitive data even though auth secrets are excluded.

### 3. Restore the shadow copy

```bash
export SNAPSHOT_DIR='.artifacts/db-sync/<timestamp>'
export CONFIRM_SHADOW_RESTORE=YES
bash scripts/db_sync_restore_shadow.sh
```

The restore script:

1. rejects an identical source/target URL when both are supplied;
2. rejects Supabase-looking targets by default;
3. creates extension-schema wrappers when uuid/pgcrypto were installed in `public`;
4. creates only the limited application-facing shadow roles, or uses pre-created Fly MPG users;
5. drops previous public shadow objects without dropping the `public` schema or PostGIS catalogs;
6. creates a sanitized `auth` compatibility surface;
7. loads the sanitized auth identity projection;
8. restores the complete `public` schema and data with `pg_restore`;
9. applies the reviewed effective runtime grants when the target allows it.

The shadow `auth.uid()` accepts either the legacy `request.jwt.claim.sub` setting or the aggregate `request.jwt.claims` JSON `sub` field. `auth.role()`, `auth.email()`, and `auth.jwt()` similarly support aggregate claims for parity clients.

Current public SQL still contains Supabase-era `auth.uid()`/`auth.jwt()` assumptions. The shadow compatibility functions exist for parity/rehearsal only. They are not a replacement authentication architecture.

If the captured extension manifest has been reviewed and is appropriate for the Fly cluster:

```bash
export APPLY_CAPTURED_EXTENSIONS=YES
```

Otherwise enable only the required supported extensions on the target before restore.

### 4. Verify table parity

```bash
bash scripts/db_sync_verify.sh
```

Verification compares the restored target against the row counts captured from the same exported snapshot as `public.dump`, not against the continuously changing live source.

It fails if:

- a source public table is missing on the target;
- the target has an unexpected public table;
- any public table row count differs;
- the sanitized auth identity count differs.

The detailed result is written to:

```text
$SNAPSHOT_DIR/parity_report.csv
```

## Application parity tests

Only after row-count parity passes:

1. point a non-customer-facing Mithril environment at the shadow database;
2. run `/ready`;
3. run booking parity endpoints against known production IDs;
4. exercise representative role-scoped/RLS reads using aggregate JWT claims;
5. map and compare users/profiles, cleaners, availability, services/pricing, properties, schedule groups, Direct placement data, payments, payouts, messaging, Quick Tasks, promotions, and every other production domain represented in `public`;
6. inventory failures caused by Supabase-specific functions, RLS, triggers, extensions, cron, storage, realtime, or Auth assumptions.

Do not switch writes yet.

## Keeping the shadow current

Re-run `scripts/db_sync_from_live.sh` for a fresh live copy. Each restore replaces the previous shadow data.

If the migration later needs a long coexistence period with continuous lag, choose CDC / logical replication only after this full restore is repeatable and verified. Do not introduce two-way replication. During migration there must be one authoritative writer until an explicit cutover.

## Cutover remains separate

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
