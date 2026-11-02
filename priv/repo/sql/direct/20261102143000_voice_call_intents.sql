-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
--
-- Short-lived record that a signed-in customer or worker tapped Call.
-- The row stores who is calling and which booking they chose. It does not
-- store the number Twilio will dial. That number is resolved again when
-- Twilio asks for call instructions.

CREATE TABLE IF NOT EXISTS public.voice_call_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  contact_role text NOT NULL CHECK (contact_role IN ('customer', 'site')),
  caller_phone_e164 text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS voice_call_intents_caller_phone_idx
  ON public.voice_call_intents (caller_phone_e164, created_at DESC);
