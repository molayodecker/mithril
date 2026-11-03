-- The service agreement can start on a date other than the day the contract was created.
ALTER TABLE public.direct_contracts
  ADD COLUMN IF NOT EXISTS start_on date;
