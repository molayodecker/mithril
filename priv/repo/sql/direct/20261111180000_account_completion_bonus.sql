-- GHS 25 for people who finish an account after we WhatsApp them.
-- The usual withdrawal floor stays GHS 50. A credited offer lowers it to GHS 25.

CREATE TABLE IF NOT EXISTS public.account_completion_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draft_id uuid,
  user_id uuid,
  phone text NOT NULL,
  offered_at timestamptz NOT NULL DEFAULT now(),
  offered_by uuid NOT NULL,
  credited_at timestamptz,
  wallet_credit_id uuid
);

CREATE UNIQUE INDEX IF NOT EXISTS account_completion_offers_phone_key
  ON public.account_completion_offers (phone);

CREATE UNIQUE INDEX IF NOT EXISTS account_completion_offers_user_key
  ON public.account_completion_offers (user_id)
  WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS account_completion_offers_credited_user_idx
  ON public.account_completion_offers (user_id)
  WHERE credited_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.account_completion_phone(text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN digits ~ '^\+[1-9][0-9]{7,14}$' THEN digits
    WHEN digits ~ '^0[0-9]{9}$' THEN '+233' || substring(digits from 2)
    WHEN digits ~ '^233[0-9]{9}$' THEN '+' || digits
    ELSE NULL
  END
  FROM (
    SELECT regexp_replace(COALESCE(btrim($1), ''), '[[:space:]().-]', '', 'g') AS digits
  ) cleaned;
$function$;

CREATE OR REPLACE FUNCTION public.fn_begin_cleaner_withdrawal(
  p_cleaner_id uuid,
  p_amount_subunit integer,
  p_withdrawal_id uuid,
  p_recipient_code text DEFAULT NULL::text,
  p_payout_method_id uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_wallet_id uuid;
  v_balance integer;
  v_min_subunit integer := 5000;
BEGIN
  IF p_cleaner_id IS NULL OR p_withdrawal_id IS NULL THEN
    RAISE EXCEPTION 'missing_cleaner_or_withdrawal_id';
  END IF;

  BEGIN
    IF EXISTS (
      SELECT 1
      FROM public.account_completion_offers o
      WHERE o.user_id = p_cleaner_id
        AND o.credited_at IS NOT NULL
    ) THEN
      v_min_subunit := 2500;
    END IF;
  EXCEPTION
    WHEN undefined_table THEN
      v_min_subunit := 5000;
  END;

  IF p_amount_subunit IS NULL OR p_amount_subunit < v_min_subunit THEN
    IF v_min_subunit = 2500 THEN
      RAISE EXCEPTION 'below_minimum_withdrawal_2500';
    ELSE
      RAISE EXCEPTION 'below_minimum_withdrawal';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.withdrawal_requests wr
    WHERE wr.id = p_withdrawal_id
      AND wr.cleaner_id = p_cleaner_id
      AND wr.amount_subunit = p_amount_subunit
  ) THEN
    RETURN p_withdrawal_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.withdrawal_requests wr
    WHERE wr.id = p_withdrawal_id
  ) THEN
    RAISE EXCEPTION 'withdrawal_id_conflict';
  END IF;

  SELECT w.id, COALESCE(w.balance_subunit, 0)
  INTO v_wallet_id, v_balance
  FROM public.wallets w
  WHERE w.user_id = p_cleaner_id
  FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    RAISE EXCEPTION 'wallet_not_found';
  END IF;

  IF v_balance < p_amount_subunit THEN
    RAISE EXCEPTION 'insufficient_balance';
  END IF;

  UPDATE public.wallets
  SET
    balance_subunit = v_balance - p_amount_subunit,
    updated_at = NOW()
  WHERE id = v_wallet_id;

  INSERT INTO public.withdrawal_requests (
    id,
    cleaner_id,
    wallet_id,
    amount_subunit,
    status,
    paystack_reference,
    bank_details,
    created_at,
    updated_at
  ) VALUES (
    p_withdrawal_id,
    p_cleaner_id,
    v_wallet_id,
    p_amount_subunit,
    'processing',
    p_withdrawal_id::text,
    jsonb_build_object(
      'recipient_code', p_recipient_code,
      'payout_method_id', p_payout_method_id
    ),
    NOW(),
    NOW()
  );

  INSERT INTO public.wallet_transactions (
    wallet_id,
    amount_subunit,
    type,
    description,
    withdrawal_request_id
  ) VALUES (
    v_wallet_id,
    p_amount_subunit,
    'debit',
    'Withdrawal pending',
    p_withdrawal_id
  );

  RETURN p_withdrawal_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_my_wallet_balance();

CREATE OR REPLACE FUNCTION public.get_my_wallet_balance()
RETURNS TABLE(balance integer, currency character varying, minimum_subunit integer)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_min integer := 5000;
BEGIN
  BEGIN
    IF EXISTS (
      SELECT 1
      FROM public.account_completion_offers o
      WHERE o.user_id = v_user
        AND o.credited_at IS NOT NULL
    ) THEN
      v_min := 2500;
    END IF;
  EXCEPTION
    WHEN undefined_table THEN
      v_min := 5000;
  END;

  RETURN QUERY
  SELECT
    COALESCE(w.balance_subunit, 0),
    COALESCE(w.currency, 'GHS'),
    v_min
  FROM public.wallets w
  WHERE w.user_id = v_user;
END;
$function$;

DO $$
BEGIN
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_my_wallet_balance() TO authenticated';
EXCEPTION
  WHEN undefined_object THEN
    NULL;
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping wallet balance grant: %', SQLERRM;
END $$;
