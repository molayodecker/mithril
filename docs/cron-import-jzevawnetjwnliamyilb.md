# Cron import from Supabase (`jzevawnetjwnliamyilb`)

Mithril Oban cron mirrors the linked Instaclean dev project's `cron.job` table.

## Source of truth in code

- Schedules and job names: `lib/mithril/cron/jobs.ex`
- SQL runners: `lib/mithril/workers/database_cron.ex`
- Native scheduled jobs: `lib/mithril/workers/scheduled_job.ex` → `Mithril.ScheduledJobs`
- Job implementations: `lib/mithril/scheduled_jobs/*` and related contexts
- Oban plugin wiring: `config/config.exs` → `Mithril.Cron.Jobs.oban_crontab/0`

## Tier 2 native (no Edge HTTP)

All former Tier 2 Edge crons run natively in Mithril:

- `admin-broadcast-worker` (parent cron + `Mithril.Workers.AdminBroadcastBatch` child batches)
- `booking-customer-reminders` (excludes `direct_booking_origins`; coordinates with `BookingReminderSweep`)
- `booking-ops-reminders`
- `booking-review-requests`
- `charge-managed-subscription-renewals`
- `cleaner-application-ops-reminders`
- `cleanup-expired-cleaning-scan-media`
- `cleanup-orphaned-quick-task-uploads`
- `cleanup-stale-ghana-card-uploads-daily`
- `message-delivery-fallback`
- `retry-payment-failure-ops-alerts`
- `sync-property-calendar-feeds` (`Mithril.PropertyCalendarSync`, `Mithril.CalendarFeedSecurity.fetch_feed_text/2`)

## Retired Tier 3 jobs

Removed from Mithril cron (and should be unscheduled in Supabase):

- `edge-function-error-alerts`
- `cleanup-old-edge-function-failures`

## Avoid double execution

While both Supabase `pg_cron` and Mithril Oban point at the same database, jobs run twice.

After verifying Mithril cron on staging, unschedule Supabase jobs (example):

```sql
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname IN (
  SELECT unnest(ARRAY[
    'admin-broadcast-worker',
    'auth_lookup_rate_limit_prune',
    'auto-close-stale-bookings',
    'booking-customer-reminders',
    'booking-ops-reminders',
    'booking-review-requests',
    'broadcast-unassigned-paid-bookings',
    'charge-managed-subscription-renewals',
    'cleaner-application-ops-reminders',
    'cleanup-expired-cleaning-scan-media',
    'cleanup-expired-welcome-promo-reservations',
    'cleanup-orphaned-quick-task-uploads',
    'cleanup-stale-ghana-card-uploads-daily',
    'escalate-unassigned-paid-bookings-past-grace',
    'expire_stale_pending_bookings_job',
    'message-delivery-fallback',
    'process-direct-assignment-holds',
    'refresh_cleaner_health_snapshots',
    'release_cleaner_hold_15min',
    'retry-payment-failure-ops-alerts',
    'sync-property-calendar-feeds'
  ]::text[])
);
```

Run that only on the environment where Mithril is the sole scheduler.

## Mithril-only cron

`BookingReminderSweep` (hourly) is **not** in Supabase `cron.job`; it handles Direct concierge reminders and avoids overlap with `booking-customer-reminders` via `direct_booking_origins` exclusion.

## Environment

Booking customer reminders (Edge parity):

- `BOOKING_CUSTOMER_REMINDER_HOURS` (default 24)
- `BOOKING_CUSTOMER_REMINDER_48H_HOURS` (default 48)
- `BOOKING_CUSTOMER_REMINDER_7D_HOURS` (default 168)
- `BOOKING_CUSTOMER_REMINDER_TOLERANCE_HOURS` (default 1)
- `BOOKING_CUSTOMER_REMINDER_MORNING_HOUR` (default 8)
- `BOOKING_REMINDER_CLAIM_TTL_MINUTES` (default 45)

Review requests:

- `BOOKING_REVIEW_REQUEST_DELAY_HOURS` (default 2)

Managed subscription renewals require `PAYSTACK_SECRET_KEY` (same as checkout).

Storage cleanups require `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.

Calendar sync requires feed URL encryption key (`OTP_DELIVERY_ENCRYPTION_KEY` / `SecretCrypto`).

## Cron-only PR scope (isolate from other WIP)

Stage only these paths for the Tier 2 migration PR. Do not bundle unrelated Sumsub, Direct, mobile gateway, or AI-match work from the same working tree.

**Required — scheduler and jobs**

- `lib/mithril/scheduled_jobs.ex`
- `lib/mithril/scheduled_jobs/*`
- `lib/mithril/cron/jobs.ex`
- `lib/mithril/workers/scheduled_job.ex`
- `lib/mithril/workers/admin_broadcast_batch.ex`
- `lib/mithril/workers/database_cron.ex` (Tier 3 SQL removals only)
- `lib/mithril/workers/booking_reminder_sweep.ex` (if touched for overlap docs only)

**Required — job implementations**

- `lib/mithril/booking_customer_reminder/*`
- `lib/mithril/booking_review_request.ex`
- `lib/mithril/subscriptions/managed_renewal.ex`
- `lib/mithril/admin_broadcast/*`
- `lib/mithril/property_calendar/*`, `lib/mithril/property_calendar_sync.ex`
- `lib/mithril/storage_cleanup/*`, `lib/mithril/object_storage.ex`
- `lib/mithril/booking_ops/*`, `lib/mithril/support_ops.ex` (native ops jobs)
- `lib/mithril/notifications/expo_push.ex`, `lib/mithril/paystack/transactions.ex`
- `lib/mithril/calendar_feed_security.ex` (fetch/sync hardening)

**Required — tests and docs**

- `test/mithril/scheduled_jobs_test.exs`, `test/mithril/cron/*`
- `test/mithril/booking_customer_reminder/*`, `test/mithril/booking_review_request_test.exs`
- `test/mithril/subscriptions/managed_renewal_test.exs`
- `test/mithril/admin_broadcast/*`, `test/mithril/storage_cleanup/*`
- `test/mithril/property_calendar/*`, `test/mithril/calendar_feed_security_fetch_test.exs`
- `test/mithril/booking_ops/*`, `test/mithril/workers/database_cron_test.exs`
- `test/support/object_storage_test_double.ex`
- `docs/cron-import-jzevawnetjwnliamyilb.md`, `.env.example` (cron env only)

**Dependencies (include if your branch needs them for compile/test)**

- `config/config.exs` / `config/runtime.exs` — Oban crontab wiring; removed `CRON_SECRET` / `SUPABASE_PROJECT_URL`
- `lib/mithril/notifications/send_notification.ex` — app reminder message types (minimal diff)
- `lib/mithril/supabase_storage.ex` — only if cleanup listing helpers were added here

**Unrelated — preserve locally, omit from cron PR**

- `lib/mithril/mobile_*`, `lib/mithril/sumsub/*`, `lib/mithril/direct_*` (except overlap docs)
- `lib/mithril_web/router.ex`, send-notification controller, WhatsApp recruitment
- `lib/mithril/uber/*`, `lib/mithril/constants/*`, rank-cleaners AI, `priv/repo/sql/direct/*`
- Most changes under `test/mithril/auth*`, `direct_*`, `mobile_*`, `whatsapp/*`

Suggested isolation (non-destructive): `git worktree add ../mithril-cron-pr <base>` and `git checkout-index` or path-wise staging — never `git reset --hard` on the main WIP tree.

## Final Oban inventory (classifications)

| Schedule | Job | Class |
|----------|-----|--------|
| `0 * * * *` | `BookingReminderSweep` | native Elixir (Direct only) |
| `*/15 * * * *` | `auth_lookup_rate_limit_prune` | native DB/RPC (`DatabaseCron`) |
| `0 * * * *` | `auto-close-stale-bookings` | native DB/RPC |
| `*/10 * * * *` | `broadcast-unassigned-paid-bookings` | native DB/RPC |
| `*/15 * * * *` | `cleanup-expired-welcome-promo-reservations` | native DB/RPC |
| `*/5 * * * *` | `escalate-unassigned-paid-bookings-past-grace` | native DB/RPC |
| `0 * * * *` | `expire_stale_pending_bookings_job` | native DB/RPC |
| `*/5 * * * *` | `process-direct-assignment-holds` | native DB/RPC |
| `15 5 * * *` | `refresh_cleaner_health_snapshots` | native DB/RPC |
| `*/5 * * * *` | `release_cleaner_hold_15min` | native DB/RPC |
| `30 * * * *` | `admin-broadcast-worker` | native Elixir |
| `0 * * * *` | `booking-customer-reminders` | native Elixir |
| `*/15 * * * *` | `booking-ops-reminders` | native Elixir |
| `15 * * * *` | `booking-review-requests` | native Elixir |
| `15 * * * *` | `charge-managed-subscription-renewals` | native Elixir |
| `0 0 * * *` | `cleaner-application-ops-reminders` | native Elixir |
| `20 * * * *` | `cleanup-expired-cleaning-scan-media` | native Elixir → DB RPC |
| `20 3 * * *` | `cleanup-orphaned-quick-task-uploads` | native Elixir |
| `0 3 * * *` | `cleanup-stale-ghana-card-uploads-daily` | native Elixir |
| `*/2 * * * *` | `message-delivery-fallback` | native Elixir |
| `*/5 * * * *` | `retry-payment-failure-ops-alerts` | native Elixir |
| `30 * * * *` | `sync-property-calendar-feeds` | native Elixir |

**Retired (do not schedule in Mithril or Supabase):** `edge-function-error-alerts`, `cleanup-old-edge-function-failures`.

**Removed Fly/env (unused after migration):** `CRON_SECRET`, `SUPABASE_PROJECT_URL` — not read under `lib/` anymore. Keep `SUPABASE_URL` + service role for object storage until R2 migration.
