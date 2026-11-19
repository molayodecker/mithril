-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- A WhatsApp ask for the client to rate the workers on a contract.
-- Staff can send one at any time. A daily job sends the next one three months later.

CREATE TABLE IF NOT EXISTS public.direct_contract_rating_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  token text NOT NULL,
  phone text NOT NULL,
  source text NOT NULL CHECK (source IN ('manual', 'automatic')),
  sent_at timestamptz NOT NULL DEFAULT now(),
  sent_by uuid,
  CONSTRAINT direct_contract_rating_requests_token_key UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS direct_contract_rating_requests_contract_sent_idx
  ON public.direct_contract_rating_requests (contract_id, sent_at DESC);

CREATE TABLE IF NOT EXISTS public.direct_contract_rating_workers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.direct_contract_rating_requests(id) ON DELETE CASCADE,
  worker_id uuid NOT NULL,
  worker_name text NOT NULL,
  rating smallint,
  comment text,
  rated_at timestamptz,
  CONSTRAINT direct_contract_rating_workers_request_worker_key UNIQUE (request_id, worker_id),
  CONSTRAINT direct_contract_rating_workers_rating_check CHECK (rating IS NULL OR rating BETWEEN 1 AND 5)
);
