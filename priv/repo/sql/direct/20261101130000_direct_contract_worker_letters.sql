-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- A worker engagement letter written when the client service agreement is created.

CREATE TABLE IF NOT EXISTS public.direct_contract_worker_letters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  client_letter_id uuid NOT NULL REFERENCES public.direct_contract_letters(id) ON DELETE CASCADE,
  assignment_id uuid NOT NULL REFERENCES public.direct_contract_assignments(id),
  worker_id uuid NOT NULL REFERENCES public.users(id),
  letter_no text NOT NULL UNIQUE,
  public_token text NOT NULL UNIQUE,
  issued_on date NOT NULL,
  start_on date NOT NULL,
  monthly_pay_minor integer NOT NULL CHECK (monthly_pay_minor > 0),
  weekly_advance_minor integer NOT NULL CHECK (weekly_advance_minor >= 0),
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  worker_name text NOT NULL,
  role_label text NOT NULL,
  client_name text NOT NULL,
  phone text,
  email text,
  preamble text NOT NULL,
  clauses jsonb NOT NULL,
  channel text CHECK (channel IS NULL OR channel IN ('email', 'whatsapp')),
  sent_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS direct_contract_worker_letters_worker_idx
  ON public.direct_contract_worker_letters (worker_id, sent_at DESC);

CREATE INDEX IF NOT EXISTS direct_contract_worker_letters_client_letter_idx
  ON public.direct_contract_worker_letters (client_letter_id, created_at DESC);
