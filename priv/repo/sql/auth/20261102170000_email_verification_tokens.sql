ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS contact_email_verified_at timestamptz;

CREATE TABLE IF NOT EXISTS public.mithril_email_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mithril_email_verifications_user_idx
  ON public.mithril_email_verifications (user_id, inserted_at DESC);
