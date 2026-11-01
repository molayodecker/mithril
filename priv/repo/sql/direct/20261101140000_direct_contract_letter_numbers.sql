-- Shared, non-reusing number allocator for client and worker letters.
-- Initialize beyond any numbers written before this migration.
CREATE SEQUENCE IF NOT EXISTS public.direct_contract_letter_no_seq;

SELECT setval(
  'public.direct_contract_letter_no_seq',
  GREATEST(
    COALESCE((
      SELECT max((substring(letter_no from '^LTR-[0-9]{4}-([0-9]+)$'))::bigint)
      FROM public.direct_contract_letters
    ), 0),
    COALESCE((
      SELECT max((substring(letter_no from '^LTR-[0-9]{4}-([0-9]+)$'))::bigint)
      FROM public.direct_contract_worker_letters
    ), 0),
    1
  ),
  EXISTS (
    SELECT 1 FROM public.direct_contract_letters
    UNION ALL
    SELECT 1 FROM public.direct_contract_worker_letters
  )
);
