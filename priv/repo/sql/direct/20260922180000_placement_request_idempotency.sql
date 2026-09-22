-- Make customer placement request creation retry-safe after ambiguous/lost responses.

ALTER TABLE public.placement_requests
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS intent_fingerprint text;

CREATE UNIQUE INDEX IF NOT EXISTS placement_requests_customer_idempotency_uidx
  ON public.placement_requests (customer_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

COMMENT ON COLUMN public.placement_requests.idempotency_key IS
  'Client-supplied per-intent key used to make placement request creation retry-safe.';

COMMENT ON COLUMN public.placement_requests.intent_fingerprint IS
  'Canonical SHA-256 fingerprint of the placement request payload bound to an idempotency key.';
