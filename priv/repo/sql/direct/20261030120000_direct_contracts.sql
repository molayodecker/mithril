-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- Ongoing client contracts: monthly fee, worker pay, weekly salary advances, and invoices.
-- An advance credits the worker wallet and is deducted on payday. It is not a Finance loan.

CREATE TABLE IF NOT EXISTS public.direct_contract_clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('company', 'person')),
  billing_contact text,
  phone text,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.direct_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL UNIQUE REFERENCES public.direct_contract_clients(id) ON DELETE CASCADE,
  monthly_fee_minor integer NOT NULL CHECK (monthly_fee_minor > 0),
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'ended')),
  placement_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS direct_contracts_status_created_idx
  ON public.direct_contracts (status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.direct_contract_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  worker_id uuid NOT NULL REFERENCES public.users(id),
  role_label text NOT NULL,
  monthly_pay_minor integer NOT NULL CHECK (monthly_pay_minor > 0),
  client_rate_minor integer NOT NULL CHECK (client_rate_minor >= 0),
  weekly_advance_minor integer CHECK (weekly_advance_minor IS NULL OR weekly_advance_minor > 0),
  advance_weekday smallint CHECK (advance_weekday IS NULL OR advance_weekday BETWEEN 0 AND 6),
  advance_mode text NOT NULL DEFAULT 'manual' CHECK (advance_mode IN ('manual', 'automatic')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'ended')),
  ended_on date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (weekly_advance_minor IS NULL AND advance_weekday IS NULL)
    OR (weekly_advance_minor IS NOT NULL AND advance_weekday IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS direct_contract_assignments_one_active_worker_idx
  ON public.direct_contract_assignments (contract_id, worker_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS direct_contract_assignments_contract_idx
  ON public.direct_contract_assignments (contract_id, created_at);

CREATE TABLE IF NOT EXISTS public.direct_contract_advances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id uuid NOT NULL REFERENCES public.direct_contract_assignments(id) ON DELETE CASCADE,
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  worker_id uuid NOT NULL REFERENCES public.users(id),
  week_on date NOT NULL,
  amount_minor integer NOT NULL CHECK (amount_minor > 0),
  paid_via text NOT NULL CHECK (paid_via IN ('manual', 'automatic')),
  paid_by uuid REFERENCES public.users(id),
  reference text NOT NULL UNIQUE,
  wallet_transaction_id uuid NOT NULL REFERENCES public.wallet_transactions(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS direct_contract_advances_assignment_week_idx
  ON public.direct_contract_advances (assignment_id, week_on);

CREATE INDEX IF NOT EXISTS direct_contract_advances_contract_week_idx
  ON public.direct_contract_advances (contract_id, week_on DESC);

CREATE TABLE IF NOT EXISTS public.direct_contract_paydays (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  period_month date NOT NULL,
  paid_by uuid NOT NULL REFERENCES public.users(id),
  total_net_minor integer NOT NULL CHECK (total_net_minor >= 0),
  paid_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS direct_contract_paydays_contract_month_idx
  ON public.direct_contract_paydays (contract_id, period_month);

CREATE TABLE IF NOT EXISTS public.direct_contract_payday_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payday_id uuid NOT NULL REFERENCES public.direct_contract_paydays(id) ON DELETE CASCADE,
  assignment_id uuid NOT NULL REFERENCES public.direct_contract_assignments(id),
  gross_minor integer NOT NULL CHECK (gross_minor >= 0),
  advances_minor integer NOT NULL CHECK (advances_minor >= 0),
  net_minor integer NOT NULL CHECK (net_minor >= 0),
  wallet_transaction_id uuid REFERENCES public.wallet_transactions(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS direct_contract_payday_lines_once_idx
  ON public.direct_contract_payday_lines (payday_id, assignment_id);

CREATE TABLE IF NOT EXISTS public.direct_contract_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.direct_contracts(id) ON DELETE CASCADE,
  period_month date NOT NULL,
  invoice_no text NOT NULL UNIQUE,
  public_token text NOT NULL UNIQUE,
  issued_on date NOT NULL,
  due_on date NOT NULL,
  style text NOT NULL CHECK (style IN ('one_line', 'per_worker')),
  total_minor integer NOT NULL CHECK (total_minor > 0),
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  channel text CHECK (channel IS NULL OR channel IN ('email', 'whatsapp')),
  sent_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS direct_contract_invoices_contract_month_idx
  ON public.direct_contract_invoices (contract_id, period_month);

CREATE TABLE IF NOT EXISTS public.direct_contract_invoice_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.direct_contract_invoices(id) ON DELETE CASCADE,
  position integer NOT NULL CHECK (position >= 0),
  description text NOT NULL,
  amount_minor integer NOT NULL CHECK (amount_minor > 0),
  assignment_id uuid REFERENCES public.direct_contract_assignments(id)
);

CREATE SEQUENCE IF NOT EXISTS public.direct_contract_wallet_ref_seq AS integer START 4101;

-- FUNCTION
CREATE OR REPLACE FUNCTION public.record_contract_wallet_credit(
  p_worker_id uuid,
  p_amount_subunit integer,
  p_recorded_by uuid,
  p_description text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_wallet_id uuid;
  v_balance integer;
  v_tx_id uuid;
  v_currency character varying(3);
  v_description text;
BEGIN
  IF p_worker_id IS NULL THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  IF session_user IS DISTINCT FROM current_user THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF p_recorded_by IS NULL THEN
    IF current_setting('mithril.contract_advance', true) IS DISTINCT FROM 'automatic' THEN
      RAISE EXCEPTION 'recorded_by_not_authorized';
    END IF;
  ELSE
    IF current_setting('mithril.actor_id', true) IS DISTINCT FROM p_recorded_by::text THEN
      RAISE EXCEPTION 'recorded_by_not_authorized';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_recorded_by) THEN
      RAISE EXCEPTION 'recorded_by_not_found';
    END IF;

    IF NOT public.admin_cash_payout_recorder_is_allowed(p_recorded_by) THEN
      RAISE EXCEPTION 'recorded_by_not_authorized';
    END IF;
  END IF;

  IF p_amount_subunit IS NULL OR p_amount_subunit <= 0 THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.cleaner_data cd WHERE cd.user_id = p_worker_id) THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  v_description := NULLIF(trim(COALESCE(p_description, '')), '');
  IF v_description IS NULL THEN
    v_description := 'Contract wallet credit';
  END IF;

  SELECT w.id, COALESCE(w.balance_subunit, 0), COALESCE(w.currency, 'GHS')
  INTO v_wallet_id, v_balance, v_currency
  FROM public.wallets w
  WHERE w.user_id = p_worker_id
  FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance_subunit, currency)
    VALUES (p_worker_id, 0, 'GHS')
    ON CONFLICT (user_id) DO NOTHING;

    SELECT w.id, COALESCE(w.balance_subunit, 0), COALESCE(w.currency, 'GHS')
    INTO v_wallet_id, v_balance, v_currency
    FROM public.wallets w
    WHERE w.user_id = p_worker_id
    FOR UPDATE;
  END IF;

  IF v_wallet_id IS NULL THEN
    RAISE EXCEPTION 'wallet_not_found';
  END IF;

  IF v_currency IS DISTINCT FROM 'GHS' THEN
    RAISE EXCEPTION 'unsupported_currency';
  END IF;

  IF v_balance > 2147483647 - p_amount_subunit THEN
    RAISE EXCEPTION 'amount_too_large';
  END IF;

  UPDATE public.wallets
  SET balance_subunit = v_balance + p_amount_subunit, updated_at = NOW()
  WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (wallet_id, booking_id, amount_subunit, type, description)
  VALUES (v_wallet_id, NULL, p_amount_subunit, 'credit', left(v_description, 240))
  RETURNING id INTO v_tx_id;

  IF p_recorded_by IS NOT NULL THEN
    INSERT INTO public.admin_wallet_credits (
      worker_id, amount_subunit, currency, notes, recorded_by, wallet_transaction_id
    ) VALUES (
      p_worker_id, p_amount_subunit, v_currency, left(v_description, 500), p_recorded_by, v_tx_id
    );
  END IF;

  RETURN jsonb_build_object(
    'wallet_transaction_id', v_tx_id,
    'new_balance_subunit', v_balance + p_amount_subunit,
    'amount_subunit', p_amount_subunit,
    'currency', v_currency
  );
END;
$function$;
