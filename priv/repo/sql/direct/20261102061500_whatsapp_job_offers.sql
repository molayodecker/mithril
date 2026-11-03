-- One open WhatsApp job offer per booking and per phone.
-- Accept and No replies are matched to this row. The booking hold
-- (assignment_hold_until / process_direct_assignment_holds) remains the
-- release clock when nobody replies.

CREATE TABLE IF NOT EXISTS public.whatsapp_job_offers (
  id uuid PRIMARY KEY,
  booking_id uuid NOT NULL,
  cleaner_id uuid NOT NULL,
  phone text NOT NULL,
  expires_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'open',
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT whatsapp_job_offers_status_check
    CHECK (status IN ('open', 'accepted', 'declined', 'expired'))
);

CREATE UNIQUE INDEX IF NOT EXISTS whatsapp_job_offers_one_open_booking_idx
  ON public.whatsapp_job_offers (booking_id)
  WHERE status = 'open';

CREATE UNIQUE INDEX IF NOT EXISTS whatsapp_job_offers_one_open_phone_idx
  ON public.whatsapp_job_offers (phone)
  WHERE status = 'open';

CREATE TABLE IF NOT EXISTS public.whatsapp_job_offer_messages (
  message_sid text PRIMARY KEY,
  phone text NOT NULL,
  reply text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
