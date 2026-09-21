-- Persist the mobile client's per-intent idempotency key so retries return
-- the same customer booking instead of creating duplicates.
--
-- This phase is intentionally idempotent because Direct schema phases are
-- replayed on every staging/production deployment.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS bookings_customer_idempotency_key_uidx
  ON public.bookings (customer_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

COMMENT ON COLUMN public.bookings.idempotency_key IS
  'Client-supplied per-intent key used to make customer booking creation retry-safe.';
