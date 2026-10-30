-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- A billing payment request is a public pay link. The amount is stored in pesewas.

CREATE TABLE IF NOT EXISTS public.direct_payment_requests (
  id uuid PRIMARY KEY,
  public_token text NOT NULL UNIQUE,
  customer_user_id uuid REFERENCES public.users(id),
  customer_name text NOT NULL,
  phone_e164 text NOT NULL,
  email text,
  description text NOT NULL,
  amount_minor integer NOT NULL CHECK (amount_minor >= 100 AND amount_minor <= 2147483647),
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  status text NOT NULL DEFAULT 'unpaid' CHECK (status IN ('unpaid', 'paid')),
  channel text CHECK (channel IN ('whatsapp', 'sms')),
  paystack_reference text NOT NULL UNIQUE,
  authorization_url text,
  delivery_error text,
  idempotency_key uuid NOT NULL,
  delivery_claimed_at timestamptz,
  twilio_message_sid text,
  sms_fallback_claimed_at timestamptz,
  sent_at timestamptz,
  remind_if_unpaid boolean NOT NULL DEFAULT false,
  reminders_sent integer NOT NULL DEFAULT 0,
  reminder_sent_at timestamptz,
  reminder_paused_at timestamptz,
  reminder_error text,
  reminder_claimed_at timestamptz,
  reminder_twilio_sid text,
  reminder_sms_fallback_claimed_at timestamptz,
  paid_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_payment_requests_idempotency UNIQUE (created_by, idempotency_key)
);

-- Existing staging tables created before the delivery claim was introduced.
ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS delivery_claimed_at timestamptz;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS twilio_message_sid text;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS sms_fallback_claimed_at timestamptz;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS remind_if_unpaid boolean NOT NULL DEFAULT false;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminder_sent_at timestamptz;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminder_claimed_at timestamptz;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminders_sent integer NOT NULL DEFAULT 0;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminder_paused_at timestamptz;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminder_error text;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminder_twilio_sid text;

ALTER TABLE public.direct_payment_requests
  ADD COLUMN IF NOT EXISTS reminder_sms_fallback_claimed_at timestamptz;

CREATE INDEX IF NOT EXISTS direct_payment_requests_created_at_idx
  ON public.direct_payment_requests (created_at DESC);

-- Preserve failed/ambiguous initialization references. A late webhook from a
-- provider attempt must still settle the original request after a safe retry.
CREATE TABLE IF NOT EXISTS public.direct_payment_request_references (
  reference text PRIMARY KEY,
  payment_request_id uuid NOT NULL REFERENCES public.direct_payment_requests(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS direct_payment_request_references_request_idx
  ON public.direct_payment_request_references (payment_request_id);

CREATE TABLE IF NOT EXISTS public.whatsapp_content_templates (
  name text PRIMARY KEY,
  content_sid text NOT NULL,
  approval_status text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
