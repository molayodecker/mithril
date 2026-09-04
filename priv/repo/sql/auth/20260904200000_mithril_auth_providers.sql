-- Provider identities, phone numbers, and OTP codes for Mithril login.

ALTER TABLE public.mithril_auth_accounts
  ALTER COLUMN email DROP NOT NULL;

ALTER TABLE public.mithril_auth_accounts
  ADD COLUMN IF NOT EXISTS phone text;

CREATE UNIQUE INDEX IF NOT EXISTS mithril_auth_accounts_phone_key
  ON public.mithril_auth_accounts (phone)
  WHERE phone IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.mithril_auth_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  provider text NOT NULL,
  provider_subject text NOT NULL,
  email text,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mithril_auth_identities_provider_subject_key UNIQUE (provider, provider_subject)
);

CREATE INDEX IF NOT EXISTS mithril_auth_identities_user_idx
  ON public.mithril_auth_identities (user_id);

CREATE TABLE IF NOT EXISTS public.mithril_auth_otps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone text NOT NULL,
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0,
  consumed_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mithril_auth_otps_phone_idx
  ON public.mithril_auth_otps (phone, inserted_at DESC);
