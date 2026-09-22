-- Make customer urgent-help creation retry-safe after ambiguous/lost responses.
-- Direct schema phases are replayed on each deploy, so keep this idempotent.

ALTER TABLE public.direct_service_requests
  ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS direct_service_requests_customer_idempotency_uidx
  ON public.direct_service_requests (customer_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

COMMENT ON COLUMN public.direct_service_requests.idempotency_key IS
  'Client-supplied per-intent key used to make Direct service-request creation retry-safe.';
