-- A committed claim freezes letter snapshots while an external send is in progress.
ALTER TABLE public.direct_contract_letters
  ADD COLUMN IF NOT EXISTS sending_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS direct_contract_letters_one_pending_idx
  ON public.direct_contract_letters (contract_id)
  WHERE sent_at IS NULL;
