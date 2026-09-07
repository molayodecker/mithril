#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"

ADMIN_URL="${DIRECT_RESERVATION_TEST_ADMIN_URL:-${DATABASE_URL%/*}/postgres}"
TEST_DB="mithril_direct_reservation_test"
TEST_URL="${ADMIN_URL%/*}/$TEST_DB"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT_DIR/priv/repo/sql/direct/20260907160000_direct_worker_schedule_reservations.sql"

cleanup() {
  psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$TEST_DB' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1 || true
  psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $TEST_DB;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $TEST_DB;"

psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE public.users (
  id uuid PRIMARY KEY
);

CREATE TABLE public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cleaner_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  booking_period tstzrange,
  status text NOT NULL DEFAULT 'pending'
);

CREATE TABLE public.direct_service_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  status text NOT NULL DEFAULT 'submitted',
  assigned_worker_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  requested_start_at timestamptz,
  duration_hours numeric
);

CREATE OR REPLACE FUNCTION public.resolve_cleaner_job_buffer_minutes()
RETURNS integer
LANGUAGE sql
STABLE
AS $$ SELECT 45 $$;
SQL

psql "$TEST_URL" -X -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null

psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.users(id)
VALUES
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

INSERT INTO public.direct_service_requests (
  id,
  kind,
  status,
  assigned_worker_user_id,
  requested_start_at,
  duration_hours
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'urgent_help',
  'assigned',
  '11111111-1111-1111-1111-111111111111',
  '2026-09-08T10:00:00Z',
  1
);
SQL

reservation_count="$(psql "$TEST_URL" -X -Atqc "
  SELECT count(*)
  FROM public.worker_schedule_reservations
  WHERE source_kind = 'direct_request'
    AND source_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
")"
[[ "$reservation_count" == "1" ]] || {
  echo "Expected one Direct schedule reservation, got $reservation_count" >&2
  exit 1
}

if psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1
INSERT INTO public.bookings (
  cleaner_id,
  booking_period,
  status
) VALUES (
  '11111111-1111-1111-1111-111111111111',
  tstzrange('2026-09-08T10:30:00Z', '2026-09-08T11:30:00Z', '[)'),
  'pending'
);
SQL
then
  echo "Overlapping booking unexpectedly bypassed the canonical worker reservation." >&2
  exit 1
fi

psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 \
  -c "UPDATE public.direct_service_requests SET status = 'resolved' WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';"

resolved_count="$(psql "$TEST_URL" -X -Atqc "
  SELECT count(*)
  FROM public.worker_schedule_reservations
  WHERE source_kind = 'direct_request'
    AND source_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
")"
[[ "$resolved_count" == "1" ]] || {
  echo "Resolving future urgent work unexpectedly released its reservation." >&2
  exit 1
}

psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 \
  -c "UPDATE public.direct_service_requests SET status = 'cancelled' WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';"

cancelled_count="$(psql "$TEST_URL" -X -Atqc "
  SELECT count(*)
  FROM public.worker_schedule_reservations
  WHERE source_kind = 'direct_request'
    AND source_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
")"
[[ "$cancelled_count" == "0" ]] || {
  echo "Cancelling urgent work did not release its reservation." >&2
  exit 1
}

psql "$TEST_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.bookings (
  cleaner_id,
  booking_period,
  status
) VALUES (
  '11111111-1111-1111-1111-111111111111',
  tstzrange('2026-09-08T10:30:00Z', '2026-09-08T11:30:00Z', '[)'),
  'pending'
);
SQL

booking_reservation_count="$(psql "$TEST_URL" -X -Atqc "
  SELECT count(*)
  FROM public.worker_schedule_reservations
  WHERE source_kind = 'booking';
")"
[[ "$booking_reservation_count" == "1" ]] || {
  echo "Expected booking write to create a canonical reservation." >&2
  exit 1
}

echo "✓ Direct worker schedule reservation migration passed"
