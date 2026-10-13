-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
-- Admin wallet credit: add money to a worker wallet with an auditable ledger row.
-- A credit with no booking id is a manual add. The existing wallet-credit notifier
-- tells the worker "GHS … was added to your Instaclean wallet."

CREATE TABLE IF NOT EXISTS public.admin_wallet_credits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  amount_subunit integer NOT NULL CHECK (amount_subunit > 0),
  currency character varying(3) NOT NULL DEFAULT 'GHS',
  notes text,
  recorded_by uuid NOT NULL REFERENCES public.users(id),
  wallet_transaction_id uuid NOT NULL REFERENCES public.wallet_transactions(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_wallet_credits_worker_created_idx
  ON public.admin_wallet_credits (worker_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.record_admin_wallet_credit(
  p_worker_id uuid,
  p_amount_subunit integer,
  p_recorded_by uuid,
  p_notes text DEFAULT NULL
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
  v_credit_id uuid;
  v_description text;
  v_currency character varying(3);
  v_notes text;
BEGIN
  IF p_worker_id IS NULL OR p_recorded_by IS NULL THEN
    RAISE EXCEPTION 'missing_required_fields';
  END IF;

  -- mithril.actor_id is set for this transaction from the authenticated session.
  -- A caller-supplied admin UUID is not enough to credit a wallet.
  IF current_setting('mithril.actor_id', true) IS DISTINCT FROM p_recorded_by::text THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_found';
  END IF;

  IF NOT public.admin_cash_payout_recorder_is_allowed(p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF p_amount_subunit IS NULL OR p_amount_subunit <= 0 THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_worker_id) THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.cleaner_data cd WHERE cd.user_id = p_worker_id) THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND length(v_notes) > 500 THEN
    RAISE EXCEPTION 'invalid_notes';
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
  SET
    balance_subunit = v_balance + p_amount_subunit,
    updated_at = NOW()
  WHERE id = v_wallet_id;

  v_description := 'Admin wallet credit';
  IF v_notes IS NOT NULL THEN
    v_description := v_description || ' — ' || left(v_notes, 120);
  END IF;

  INSERT INTO public.wallet_transactions (
    wallet_id,
    booking_id,
    amount_subunit,
    type,
    description
  ) VALUES (
    v_wallet_id,
    NULL,
    p_amount_subunit,
    'credit',
    v_description
  )
  RETURNING id INTO v_tx_id;

  INSERT INTO public.admin_wallet_credits (
    worker_id,
    amount_subunit,
    currency,
    notes,
    recorded_by,
    wallet_transaction_id
  ) VALUES (
    p_worker_id,
    p_amount_subunit,
    v_currency,
    v_notes,
    p_recorded_by,
    v_tx_id
  )
  RETURNING id INTO v_credit_id;

  RETURN jsonb_build_object(
    'credit_id', v_credit_id,
    'wallet_transaction_id', v_tx_id,
    'new_balance_subunit', v_balance + p_amount_subunit,
    'amount_subunit', p_amount_subunit,
    'currency', v_currency
  );
END;
$function$;

COMMENT ON FUNCTION public.record_admin_wallet_credit(uuid, integer, uuid, text) IS
  'Atomically credit a worker wallet for an admin-recorded add. Creates a GHS wallet when the worker does not have one yet.';

-- The function owner is the only executor. Credits also require mithril.actor_id
-- to equal p_recorded_by. Do not GRANT EXECUTE to PUBLIC.
REVOKE ALL ON FUNCTION public.record_admin_wallet_credit(uuid, integer, uuid, text) FROM PUBLIC;
