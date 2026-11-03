-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- Drawn signatures for the service agreement and the worker engagement.

ALTER TABLE public.direct_contracts
  ADD COLUMN IF NOT EXISTS provider_signer_name text,
  ADD COLUMN IF NOT EXISTS provider_signed_at timestamptz,
  ADD COLUMN IF NOT EXISTS provider_signature text;

ALTER TABLE public.direct_contract_letters
  ADD COLUMN IF NOT EXISTS provider_signer_name text,
  ADD COLUMN IF NOT EXISTS provider_signed_at timestamptz,
  ADD COLUMN IF NOT EXISTS provider_signature text,
  ADD COLUMN IF NOT EXISTS client_signer_name text,
  ADD COLUMN IF NOT EXISTS client_signed_at timestamptz,
  ADD COLUMN IF NOT EXISTS client_signature text;

ALTER TABLE public.direct_contract_worker_letters
  ADD COLUMN IF NOT EXISTS provider_signer_name text,
  ADD COLUMN IF NOT EXISTS provider_signed_at timestamptz,
  ADD COLUMN IF NOT EXISTS provider_signature text,
  ADD COLUMN IF NOT EXISTS worker_signer_name text,
  ADD COLUMN IF NOT EXISTS worker_signed_at timestamptz,
  ADD COLUMN IF NOT EXISTS worker_signature text;
