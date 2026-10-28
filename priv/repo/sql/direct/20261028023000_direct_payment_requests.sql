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
  sent_at timestamptz,
  paid_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_payment_requests_idempotency UNIQUE (created_by, idempotency_key)
);

CREATE INDEX IF NOT EXISTS direct_payment_requests_created_at_idx
  ON public.direct_payment_requests (created_at DESC);

CREATE TABLE IF NOT EXISTS public.whatsapp_content_templates (
  name text PRIMARY KEY,
  content_sid text NOT NULL,
  approval_status text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
