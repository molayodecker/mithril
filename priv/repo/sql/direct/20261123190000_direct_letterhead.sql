-- One line shown under the Instaclean name on contract letters.
CREATE TABLE IF NOT EXISTS public.direct_letter_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  letterhead text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.direct_letter_settings
  DROP CONSTRAINT IF EXISTS direct_letter_settings_letterhead_length;

ALTER TABLE public.direct_letter_settings
  ADD CONSTRAINT direct_letter_settings_letterhead_length
  CHECK (letterhead IS NULL OR char_length(letterhead) <= 180);

INSERT INTO public.direct_letter_settings (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;
