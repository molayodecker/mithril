-- The office letter keeps a from address, a client address, and the letter text.
ALTER TABLE public.direct_letter_settings
  ADD COLUMN IF NOT EXISTS from_name text;

ALTER TABLE public.direct_letter_settings
  ADD COLUMN IF NOT EXISTS from_address text;

ALTER TABLE public.direct_letter_settings
  ADD COLUMN IF NOT EXISTS client_name text;

ALTER TABLE public.direct_letter_settings
  ADD COLUMN IF NOT EXISTS client_address text;

ALTER TABLE public.direct_letter_settings
  ADD COLUMN IF NOT EXISTS body text;

ALTER TABLE public.direct_letter_settings
  DROP CONSTRAINT IF EXISTS direct_letter_settings_from_name_length;

ALTER TABLE public.direct_letter_settings
  ADD CONSTRAINT direct_letter_settings_from_name_length
  CHECK (from_name IS NULL OR char_length(from_name) <= 120);

ALTER TABLE public.direct_letter_settings
  DROP CONSTRAINT IF EXISTS direct_letter_settings_from_address_length;

ALTER TABLE public.direct_letter_settings
  ADD CONSTRAINT direct_letter_settings_from_address_length
  CHECK (from_address IS NULL OR char_length(from_address) <= 500);

ALTER TABLE public.direct_letter_settings
  DROP CONSTRAINT IF EXISTS direct_letter_settings_client_name_length;

ALTER TABLE public.direct_letter_settings
  ADD CONSTRAINT direct_letter_settings_client_name_length
  CHECK (client_name IS NULL OR char_length(client_name) <= 120);

ALTER TABLE public.direct_letter_settings
  DROP CONSTRAINT IF EXISTS direct_letter_settings_client_address_length;

ALTER TABLE public.direct_letter_settings
  ADD CONSTRAINT direct_letter_settings_client_address_length
  CHECK (client_address IS NULL OR char_length(client_address) <= 500);

ALTER TABLE public.direct_letter_settings
  DROP CONSTRAINT IF EXISTS direct_letter_settings_body_length;

ALTER TABLE public.direct_letter_settings
  ADD CONSTRAINT direct_letter_settings_body_length
  CHECK (body IS NULL OR char_length(body) <= 4000);
