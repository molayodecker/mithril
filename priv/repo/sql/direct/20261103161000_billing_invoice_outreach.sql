-- Client outreach on a custom invoice: send, approval, location, and the proposed team.
-- The invoice stays independent until the client approves. booking_id is filled when
-- that approval can be turned into a visit.

ALTER TABLE public.admin_billing_invoices
  ADD COLUMN IF NOT EXISTS public_token text,
  ADD COLUMN IF NOT EXISTS approval_status text NOT NULL DEFAULT 'draft',
  ADD COLUMN IF NOT EXISTS approval_note text,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS booking_id uuid,
  ADD COLUMN IF NOT EXISTS service_address text,
  ADD COLUMN IF NOT EXISTS proposed_workers jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS invoice_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS invoice_sent_channel text,
  ADD COLUMN IF NOT EXISTS approval_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS approval_requested_channel text,
  ADD COLUMN IF NOT EXISTS location_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS location_requested_channel text,
  ADD COLUMN IF NOT EXISTS team_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS team_sent_channel text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'admin_billing_invoices_approval_status_check'
  ) THEN
    ALTER TABLE public.admin_billing_invoices
      ADD CONSTRAINT admin_billing_invoices_approval_status_check
      CHECK (approval_status IN ('draft', 'awaiting_approval', 'approved', 'changes_requested'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS admin_billing_invoices_public_token_idx
  ON public.admin_billing_invoices (public_token);
