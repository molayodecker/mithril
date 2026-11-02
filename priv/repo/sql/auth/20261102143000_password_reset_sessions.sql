-- Password-reset emails issue a short-lived refresh token. Mark those rows so
-- a later refresh cannot turn the link into a normal 30-day session.
ALTER TABLE public.mithril_refresh_tokens
  ADD COLUMN IF NOT EXISTS purpose text;

CREATE TABLE IF NOT EXISTS public.mithril_password_resets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  access_token_hash text UNIQUE,
  used_at timestamptz,
  expires_at timestamptz NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mithril_password_resets_user_recent_idx
  ON public.mithril_password_resets (user_id, inserted_at DESC);

-- Support installations where the table was created before these hardening fields.
ALTER TABLE public.mithril_password_resets
  ADD COLUMN IF NOT EXISTS access_token_hash text,
  ADD COLUMN IF NOT EXISTS used_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS mithril_password_resets_access_hash_idx
  ON public.mithril_password_resets (access_token_hash);
