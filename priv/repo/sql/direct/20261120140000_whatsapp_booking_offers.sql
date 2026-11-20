-- WhatsApp booking offers. A booking row is created only after the customer
-- picks a time, so the offer can carry the staff price before a cleaner exists.

CREATE TABLE IF NOT EXISTS public.whatsapp_booking_offers (
  id uuid PRIMARY KEY,
  customer_id uuid NOT NULL,
  phone text NOT NULL,
  service_id integer NOT NULL,
  service_name text NOT NULL,
  amount_minor integer NOT NULL,
  currency text NOT NULL DEFAULT 'GHS',
  address text NOT NULL,
  latitude double precision,
  longitude double precision,
  duration_hours numeric NOT NULL DEFAULT 2,
  status text NOT NULL DEFAULT 'offered',
  booking_id uuid,
  cleaner_id uuid,
  cleaner_name text,
  slot_base_date date,
  scheduled_date date,
  scheduled_time time,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT whatsapp_booking_offers_amount_check CHECK (amount_minor >= 100),
  CONSTRAINT whatsapp_booking_offers_status_check
    CHECK (status IN ('offered', 'awaiting_time', 'assigned'))
);

CREATE UNIQUE INDEX IF NOT EXISTS whatsapp_booking_offers_one_open_phone
  ON public.whatsapp_booking_offers (phone)
  WHERE status IN ('offered', 'awaiting_time');

CREATE TABLE IF NOT EXISTS public.whatsapp_booking_offer_messages (
  message_sid text PRIMARY KEY,
  phone text NOT NULL,
  reply text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Existing installs may already have the table from an earlier deployment.
ALTER TABLE public.whatsapp_booking_offers
  ADD COLUMN IF NOT EXISTS slot_base_date date;
