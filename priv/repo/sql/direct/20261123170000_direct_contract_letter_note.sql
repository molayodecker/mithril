-- A service agreement can include one extra sentence.
ALTER TABLE public.direct_contracts
  ADD COLUMN IF NOT EXISTS letter_note text;

ALTER TABLE public.direct_contracts
  DROP CONSTRAINT IF EXISTS direct_contracts_letter_note_length;

ALTER TABLE public.direct_contracts
  ADD CONSTRAINT direct_contracts_letter_note_length
  CHECK (letter_note IS NULL OR char_length(letter_note) <= 500);
