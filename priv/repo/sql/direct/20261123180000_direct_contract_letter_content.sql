-- A service agreement can keep edited letter wording.
ALTER TABLE public.direct_contracts
  ADD COLUMN IF NOT EXISTS letter_content jsonb;

ALTER TABLE public.direct_contracts
  DROP CONSTRAINT IF EXISTS direct_contracts_letter_content_size;

ALTER TABLE public.direct_contracts
  ADD CONSTRAINT direct_contracts_letter_content_size
  CHECK (letter_content IS NULL OR octet_length(letter_content::text) <= 100000);
