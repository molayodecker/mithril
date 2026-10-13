-- Signatory title shown under the invoice signature line (e.g. Operations Manager).

ALTER TABLE public.job_invoices
  ADD COLUMN IF NOT EXISTS signatory_role text;

ALTER TABLE public.admin_billing_invoices
  ADD COLUMN IF NOT EXISTS signatory_role text;
