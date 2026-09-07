-- Auditable refund-request queue for human/agent initiated operations.
--
-- A request is not a Paystack refund. It records intent and the policy-derived
-- amount for review/processing by the canonical payment workflow.

CREATE TABLE IF NOT EXISTS public.direct_refund_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  customer_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  requested_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested', 'reviewing', 'approved', 'processing', 'processed', 'rejected', 'cancelled')),
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  policy_tier text
    CHECK (policy_tier IS NULL OR policy_tier IN ('full_refund', 'partial_refund', 'no_refund')),
  proposed_refund_percent integer
    CHECK (proposed_refund_percent IS NULL OR proposed_refund_percent IN (0, 50, 100)),
  proposed_refund_amount_minor bigint
    CHECK (proposed_refund_amount_minor IS NULL OR proposed_refund_amount_minor >= 0),
  source text NOT NULL DEFAULT 'mcp'
    CHECK (source IN ('mcp', 'admin', 'customer', 'phone', 'whatsapp')),
  admin_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS direct_refund_requests_customer_idx
  ON public.direct_refund_requests (customer_id, created_at DESC);

CREATE INDEX IF NOT EXISTS direct_refund_requests_status_idx
  ON public.direct_refund_requests (status, created_at ASC);

CREATE UNIQUE INDEX IF NOT EXISTS direct_refund_requests_active_booking_uniq
  ON public.direct_refund_requests (booking_id)
  WHERE status IN ('requested', 'reviewing', 'approved', 'processing');

DROP TRIGGER IF EXISTS direct_refund_requests_set_updated_at
  ON public.direct_refund_requests;
CREATE TRIGGER direct_refund_requests_set_updated_at
BEFORE UPDATE ON public.direct_refund_requests
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
