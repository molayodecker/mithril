-- Track the canonical refund-ledger baseline captured when each Direct refund
-- request is created. A processed request is reconciled only after
-- booking_refunds reflects at least baseline + proposed amount.
--
-- Existing processed rows intentionally remain NULL and therefore fail closed
-- until they are manually reconciled/backfilled.

ALTER TABLE public.direct_refund_requests
  ADD COLUMN IF NOT EXISTS canonical_refunded_amount_minor_at_request bigint;

ALTER TABLE public.direct_refund_requests
  DROP CONSTRAINT IF EXISTS direct_refund_requests_canonical_refund_baseline_check;

ALTER TABLE public.direct_refund_requests
  ADD CONSTRAINT direct_refund_requests_canonical_refund_baseline_check
  CHECK (
    canonical_refunded_amount_minor_at_request IS NULL
    OR canonical_refunded_amount_minor_at_request >= 0
  );
