-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- A service agreement issued from a client contract. The stored text is the letter that was sent.

CREATE TABLE IF NOT EXISTS public.direct_contract_letters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  letter_no text NOT NULL UNIQUE,
  public_token text NOT NULL UNIQUE,
  issued_on date NOT NULL,
  start_on date NOT NULL,
  monthly_fee_minor integer NOT NULL CHECK (monthly_fee_minor > 0),
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  client_name text NOT NULL,
  billing_contact text,
  phone text,
  email text,
  preamble text NOT NULL,
  workers jsonb NOT NULL,
  clauses jsonb NOT NULL,
  channel text CHECK (channel IS NULL OR channel IN ('email', 'whatsapp')),
  sent_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS direct_contract_letters_contract_idx
  ON public.direct_contract_letters (contract_id, created_at DESC);
