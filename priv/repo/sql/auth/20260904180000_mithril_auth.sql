-- Mithril-owned login accounts and refresh tokens.
-- Password hashes may be imported from live Supabase auth.users.

CREATE TABLE IF NOT EXISTS public.mithril_auth_accounts (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  password_hash text,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mithril_auth_accounts_email_key UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS mithril_auth_accounts_email_lower_idx
  ON public.mithril_auth_accounts (lower(email));

CREATE TABLE IF NOT EXISTS public.mithril_refresh_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mithril_refresh_tokens_user_idx
  ON public.mithril_refresh_tokens (user_id, expires_at)
  WHERE revoked_at IS NULL;
