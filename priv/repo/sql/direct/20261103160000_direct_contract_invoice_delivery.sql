-- Allocate invoice numbers without reusing numbers removed from the table.
CREATE SEQUENCE IF NOT EXISTS public.direct_contract_invoice_no_seq;

SELECT setval(
  'public.direct_contract_invoice_no_seq',
  GREATEST(COALESCE(MAX(substring(invoice_no FROM '^INV-[0-9]{4}-([0-9]+)$')::bigint), 0), 1),
  COUNT(substring(invoice_no FROM '^INV-[0-9]{4}-([0-9]+)$')) > 0
)
FROM public.direct_contract_invoices;

-- A durable delivery claim prevents deleting the invoice while its URL is being sent.
ALTER TABLE public.direct_contract_invoices
  ADD COLUMN IF NOT EXISTS sending_at timestamptz;
