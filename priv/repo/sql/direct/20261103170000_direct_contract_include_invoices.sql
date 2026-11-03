-- A service agreement can leave out the invoices clause.
ALTER TABLE public.direct_contracts
  ADD COLUMN IF NOT EXISTS include_invoices boolean NOT NULL DEFAULT true;
