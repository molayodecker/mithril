-- One store-update policy per mobile app and release channel.
-- Existing rows are the customer app. Worker rows are not inserted here:
-- installed customer builds still read by channel alone, and a second row
-- for the same channel makes that read fail open.

ALTER TABLE public.app_update_policy
  ADD COLUMN IF NOT EXISTS app text;

UPDATE public.app_update_policy
SET app = 'customer'
WHERE app IS NULL OR btrim(app) = '';

ALTER TABLE public.app_update_policy
  ALTER COLUMN app SET DEFAULT 'customer';

ALTER TABLE public.app_update_policy
  ALTER COLUMN app SET NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.app_update_policy'::regclass
      AND conname = 'app_update_policy_pkey'
      AND pg_get_constraintdef(oid) NOT LIKE '%app%'
  ) THEN
    ALTER TABLE public.app_update_policy DROP CONSTRAINT app_update_policy_pkey;
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.app_update_policy'::regclass
      AND conname = 'app_update_policy_pkey'
  ) THEN
    ALTER TABLE public.app_update_policy
      ADD CONSTRAINT app_update_policy_pkey PRIMARY KEY (app, channel);
  END IF;
END
$$;

ALTER TABLE public.app_update_policy
  DROP CONSTRAINT IF EXISTS app_update_policy_app_check;

ALTER TABLE public.app_update_policy
  ADD CONSTRAINT app_update_policy_app_check
  CHECK (app IN ('customer', 'worker'));
