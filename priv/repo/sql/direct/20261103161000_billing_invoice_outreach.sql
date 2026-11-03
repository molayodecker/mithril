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

-- Preserve the exact commercial terms the client approved. Address and delivery
-- metadata remain editable without altering the approved consideration.
CREATE OR REPLACE FUNCTION public.prevent_approved_billing_invoice_terms_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.approval_status = 'approved'
     AND (OLD.issued_on, OLD.bill_to_name, OLD.project, OLD.lines,
          OLD.adjustment_minor, OLD.subtotal_minor, OLD.total_minor,
          OLD.currency, OLD.notes, OLD.signatory_role)
         IS DISTINCT FROM
         (NEW.issued_on, NEW.bill_to_name, NEW.project, NEW.lines,
          NEW.adjustment_minor, NEW.subtotal_minor, NEW.total_minor,
          NEW.currency, NEW.notes, NEW.signatory_role) THEN
    RAISE EXCEPTION 'approved_invoice_immutable';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_approved_billing_invoice_terms
  ON public.admin_billing_invoices;
CREATE TRIGGER protect_approved_billing_invoice_terms
BEFORE UPDATE ON public.admin_billing_invoices
FOR EACH ROW EXECUTE FUNCTION public.prevent_approved_billing_invoice_terms_change();

ALTER TABLE public.admin_billing_invoices
  ADD COLUMN IF NOT EXISTS team_sending_at timestamptz;
