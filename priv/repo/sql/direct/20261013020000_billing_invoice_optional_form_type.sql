-- Custom invoices are standard job invoices; tax form applies to payment advice only.

ALTER TABLE public.admin_billing_invoices
  ALTER COLUMN form_type DROP NOT NULL;

ALTER TABLE public.admin_billing_invoices
  DROP CONSTRAINT IF EXISTS admin_billing_invoices_form_type_check;

ALTER TABLE public.admin_billing_invoices
  ADD CONSTRAINT admin_billing_invoices_form_type_check
  CHECK (form_type IS NULL OR form_type IN ('w8ben', '1099'));
