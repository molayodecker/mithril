ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS contact_email_verified_at timestamptz;

CREATE TABLE IF NOT EXISTS public.mithril_email_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

-- Preserve correctness if this migration's initial table creation ran before the email column existed.
ALTER TABLE public.mithril_email_verifications
  ADD COLUMN IF NOT EXISTS email text;

-- Any email write path (including /mobile/query) must invalidate the old verification.
CREATE OR REPLACE FUNCTION public.mithril_invalidate_contact_email_verification()
RETURNS trigger
LANGUAGE plpgsql
AS $
BEGIN
  IF lower(btrim(coalesce(OLD.email, ''))) IS DISTINCT FROM
     lower(btrim(coalesce(NEW.email, ''))) THEN
    NEW.contact_email_verified_at := NULL;
  END IF;
  RETURN NEW;
END;
$;

DROP TRIGGER IF EXISTS mithril_contact_email_changed ON public.users;
CREATE TRIGGER mithril_contact_email_changed
BEFORE UPDATE OF email ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.mithril_invalidate_contact_email_verification();

CREATE INDEX IF NOT EXISTS mithril_email_verifications_user_idx
  ON public.mithril_email_verifications (user_id, inserted_at DESC);
