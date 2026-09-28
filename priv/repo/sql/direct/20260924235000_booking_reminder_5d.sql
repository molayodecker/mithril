-- Customer ~5 day reminder stamp for one-time bookings.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS customer_reminder_5d_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS customer_reminder_5d_claimed_at timestamptz;

COMMENT ON COLUMN public.bookings.customer_reminder_5d_sent_at IS
  'Set after the customer ~5 day reminder delivers for a one-time booking.';
COMMENT ON COLUMN public.bookings.customer_reminder_5d_claimed_at IS
  'In-flight claim for the customer 5 day reminder; TTL allows retry.';
