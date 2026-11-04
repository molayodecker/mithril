-- Numbers Twilio refused because they are not registered on WhatsApp.
-- 63003 and 63024 are recorded here so a later WhatsApp send can stop
-- before calling Twilio again.

CREATE TABLE IF NOT EXISTS public.whatsapp_unreachable_numbers (
  phone_e164 text PRIMARY KEY,
  twilio_code integer NOT NULL CHECK (twilio_code IN (63003, 63024)),
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
