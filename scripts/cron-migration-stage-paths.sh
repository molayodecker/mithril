#!/usr/bin/env bash
# Non-destructive helper: print paths to stage for a cron-only PR.
# Run from repo root: bash scripts/cron-migration-stage-paths.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "# Required cron migration paths (git add these for the Tier 2 PR)"
cat <<'PATHS'
lib/mithril/scheduled_jobs.ex
lib/mithril/scheduled_jobs/
lib/mithril/cron/
lib/mithril/workers/scheduled_job.ex
lib/mithril/workers/admin_broadcast_batch.ex
lib/mithril/workers/database_cron.ex
lib/mithril/booking_customer_reminder/
lib/mithril/booking_review_request.ex
lib/mithril/subscriptions/managed_renewal.ex
lib/mithril/admin_broadcast/
lib/mithril/property_calendar/
lib/mithril/property_calendar_sync.ex
lib/mithril/storage_cleanup/
lib/mithril/object_storage.ex
lib/mithril/booking_ops/
lib/mithril/support_ops.ex
lib/mithril/notifications/expo_push.ex
lib/mithril/paystack/transactions.ex
lib/mithril/calendar_feed_security.ex
test/mithril/scheduled_jobs/
test/mithril/cron/
test/mithril/booking_customer_reminder/
test/mithril/booking_review_request_test.exs
test/mithril/subscriptions/
test/mithril/admin_broadcast/
test/mithril/storage_cleanup/
test/mithril/property_calendar/
test/mithril/calendar_feed_security_fetch_test.exs
test/mithril/booking_ops/
test/mithril/workers/database_cron_test.exs
test/support/object_storage_test_double.ex
docs/cron-import-jzevawnetjwnliamyilb.md
scripts/cron-migration-stage-paths.sh
PATHS

echo ""
echo "# Dependency paths (add if changed on your branch for compile/oban)"
cat <<'DEPS'
config/config.exs
config/runtime.exs
.env.example
lib/mithril/notifications/send_notification.ex
lib/mithril/supabase_storage.ex
DEPS

echo ""
echo "# Unrelated paths currently dirty — do NOT stage for cron PR (preserve locally):"
git status --short | awk '{print $2}' | rg -v \
  '^(lib/mithril/(scheduled_jobs|cron|booking_customer_reminder|booking_review_request|subscriptions/managed_renewal|admin_broadcast|property_calendar|property_calendar_sync|storage_cleanup|object_storage|booking_ops|support_ops|notifications/expo_push|paystack/transactions|calendar_feed_security|workers/(scheduled_job|admin_broadcast_batch|database_cron))|test/mithril/(scheduled_jobs|cron|booking_customer_reminder|booking_review_request|subscriptions|admin_broadcast|storage_cleanup|property_calendar|calendar_feed_security_fetch|booking_ops|workers/database_cron)|test/support/object_storage|docs/cron-import|scripts/cron-migration)' \
  || true
