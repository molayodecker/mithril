# May 20, 2026 R2 backup inspection

This note records an inspection of the two PostgreSQL backup artifacts stored under the Cloudflare R2 production backup prefix `2026-05-20/26137003002/`.

## Artifacts inspected

- `schema.sql.gz`
- `functions_triggers.sql.gz`

The inspected upload filenames were:

- `2026-05-20_26137003002_schema.sql.gz`
- `2026-05-20_26137003002_functions_triggers.sql.gz`

SHA-256 checksums of the compressed files:

```text
schema.sql.gz
34e628ccceee76d149dce0c1fc1bb6b72844e642f5003f158fac16fb1c592983

functions_triggers.sql.gz
3566e4388c00e9d45ed146605c07830f054ccbb42feeaf0ee1042189dcf2786b
```

Both gzip streams decompress successfully.

## Critical finding: these are not data backups

Neither file contains table row data.

Observed in both files:

```text
COPY statements: 0
INSERT INTO statements: 0
```

Therefore these artifacts cannot restore production customers, cleaners, bookings, payments, wallets, messages, or other application rows.

They are useful as a structural and database-logic snapshot, but a fresh data/full dump is still required for a Fly Managed Postgres production migration.

## `schema.sql.gz` contents

The schema dump contains the public Instaclean relational structure and database logic.

Observed counts:

```text
public tables: 68
sequences: 7
views: 2
indexes: 156
RLS policies: 147
application function definitions: 88
```

All 68 public tables have RLS enabled in this snapshot.

Representative tables include:

- `bookings`
- `cleaner_data`
- `availability`
- `cleaner_schedules`
- `profiles`
- `users`
- `transactions`
- `wallets`
- `wallet_transactions`
- `withdrawal_requests`
- `messages`
- `conversations`
- `subscriptions`
- `pricing_rules`
- `platform_fees`
- `payout_methods`

## Extensions requested by the schema dump

The dump contains extension creation statements for:

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

Do not replay this list blindly into Fly Managed Postgres.

Fly MPG supports trusted extensions from the default PostgreSQL distribution plus selected third-party extensions including PostGIS. Supabase-specific or other third-party extensions such as `pg_net`, `pg_cron`, and `supabase_vault` must be removed, replaced, or otherwise accounted for before cutover.

PostGIS should be provisioned through Fly MPG rather than recreated by replaying extension-owned function definitions.

## Supabase Auth coupling

The public schema is tightly coupled to the Supabase `auth` schema.

Important findings:

- the schema dump does not create `auth.users`
- the schema dump does not create the `auth` schema
- 25 foreign keys reference `auth.users`
- many functions and RLS policies call `auth.uid()`
- grants reference Supabase roles such as `anon`, `authenticated`, and `service_role`

The public-schema dump therefore is not independently restorable into a vanilla Fly MPG database without an auth compatibility plan.

This is a migration blocker that should be solved deliberately, not patched during production cutover.

Recommended direction for Mithril:

1. keep Supabase Auth issuing JWTs during the Phoenix migration
2. make Phoenix validate those JWTs directly
3. remove application authorization dependence on `auth.uid()` and Supabase database roles over time
4. migrate or replace the 25 `auth.users` foreign-key relationships with a Mithril-owned identity boundary, most likely `public.users` / a dedicated identity table
5. retire auth-table triggers after equivalent Phoenix behavior exists

Trying to keep a live Supabase Auth database and a separate Fly public database while preserving hard foreign keys to Supabase `auth.users` is not viable across database servers.

## Supplemental functions/triggers dump

`functions_triggers.sql.gz` contains:

```text
function definitions: 1003
active triggers: 19
```

Only four of those functions are under `auth`; 999 are under `public`.

The very high public function count is because the supplemental script captured extension-owned functions as well as Instaclean application functions. It includes a large PostGIS function surface and other extension internals.

Do not replay all 1003 functions into Fly MPG. Let Fly install supported extensions and restore only Instaclean-owned functions that are still required.

The active triggers include 5 triggers against Supabase auth tables and 14 against public application tables.

Auth-table triggers include synchronization/provisioning hooks on `auth.users` and `auth.identities`.

Public-table triggers include booking scheduling/payment guards, completion/status logging, cleaner wallet creation, conversation timestamp synchronization, platform fee guards, and updated-at helpers.

These should be classified individually as one of:

- retain temporarily in PostgreSQL
- replace with a PostgreSQL-compatible version
- move into a Phoenix context / `Ecto.Multi`
- replace with a durable background job where side effects are involved

## `pg_net` dependency

At least one application function uses `net.http_post` to call a Supabase Edge Function for Paystack customer provisioning.

That pattern should not be carried into Fly MPG.

Move outbound HTTP side effects into Mithril/Phoenix, with idempotency and durable retry semantics where appropriate.

## Restore strategy

Use these May artifacts for analysis and migration rehearsal only.

Do not treat them as the production migration source.

For the final database cutover:

1. provision Fly Managed Postgres with PostGIS
2. inventory supported extensions on the target
3. decouple or provide a deliberate compatibility layer for Supabase Auth references
4. generate a fresh complete dump from the live Supabase database
5. restore into a non-production Fly MPG database first
6. verify row counts and critical invariants
7. validate PostGIS availability queries, RLS/security behavior, booking state transitions, pricing, wallets, payments, and triggers
8. perform a final synchronized cutover with a fresh data snapshot or controlled write pause
9. switch Mithril `DATABASE_URL`
10. retain Supabase temporarily for rollback until production verification is complete

## Conclusion

The R2 artifacts are valuable because they preserve the shape and much of the behavior of the May 20 database, but they are not a full database backup.

Their main migration value is as a reference snapshot for extracting Instaclean-owned DDL and identifying Supabase coupling before the live Fly MPG migration.