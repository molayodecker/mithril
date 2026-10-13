-- Worker loan / advance requests: workers ask, admins approve (wallet credit + outstanding balance).

CREATE TABLE IF NOT EXISTS public.worker_loan_accounts (
  worker_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  outstanding_minor integer NOT NULL DEFAULT 0 CHECK (outstanding_minor >= 0),
  currency character varying(3) NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.worker_loan_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  amount_minor integer NOT NULL CHECK (amount_minor > 0),
  reason text,
  status text NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  reviewed_by uuid REFERENCES public.users(id),
  review_notes text,
  reviewed_at timestamptz,
  wallet_transaction_id uuid REFERENCES public.wallet_transactions(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS worker_loan_requests_status_created_idx
  ON public.worker_loan_requests (status, created_at DESC);

CREATE INDEX IF NOT EXISTS worker_loan_requests_worker_created_idx
  ON public.worker_loan_requests (worker_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS worker_loan_requests_one_pending_per_worker_idx
  ON public.worker_loan_requests (worker_id)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS public.worker_loan_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  request_id uuid REFERENCES public.worker_loan_requests(id),
  event_type text NOT NULL CHECK (event_type IN ('disbursement', 'repayment')),
  amount_minor integer NOT NULL CHECK (amount_minor > 0),
  outstanding_after_minor integer NOT NULL CHECK (outstanding_after_minor >= 0),
  wallet_transaction_id uuid REFERENCES public.wallet_transactions(id),
  recorded_by uuid REFERENCES public.users(id),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS worker_loan_events_worker_created_idx
  ON public.worker_loan_events (worker_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.create_worker_loan_request(
  p_worker_id uuid,
  p_amount_minor integer,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_reason text;
  v_request_id uuid;
BEGIN
  IF p_worker_id IS NULL THEN
    RAISE EXCEPTION 'missing_required_fields';
  END IF;

  IF session_user IS DISTINCT FROM current_user THEN
    RAISE EXCEPTION 'actor_not_authorized';
  END IF;

  IF current_setting('mithril.actor_id', true) IS DISTINCT FROM p_worker_id::text THEN
    RAISE EXCEPTION 'actor_not_authorized';
  END IF;

  IF p_amount_minor IS NULL OR p_amount_minor <= 0 OR p_amount_minor > 2147483647 THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.cleaner_data cd WHERE cd.user_id = p_worker_id) THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  v_reason := NULLIF(trim(COALESCE(p_reason, '')), '');
  IF v_reason IS NOT NULL AND length(v_reason) > 500 THEN
    RAISE EXCEPTION 'invalid_reason';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.worker_loan_requests r
    WHERE r.worker_id = p_worker_id AND r.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'pending_request_exists';
  END IF;

  INSERT INTO public.worker_loan_requests (worker_id, amount_minor, reason, status)
  VALUES (p_worker_id, p_amount_minor, v_reason, 'pending')
  RETURNING id INTO v_request_id;

  RETURN jsonb_build_object(
    'id', v_request_id,
    'workerId', p_worker_id,
    'amountMinor', p_amount_minor,
    'reason', v_reason,
    'status', 'pending'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.review_worker_loan_request(
  p_request_id uuid,
  p_reviewer_id uuid,
  p_decision text,
  p_review_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row public.worker_loan_requests%ROWTYPE;
  v_notes text;
  v_wallet_id uuid;
  v_balance integer;
  v_currency character varying(3);
  v_tx_id uuid;
  v_outstanding integer;
  v_event_id uuid;
  v_description text;
BEGIN
  IF p_request_id IS NULL OR p_reviewer_id IS NULL OR p_decision IS NULL THEN
    RAISE EXCEPTION 'missing_required_fields';
  END IF;

  IF session_user IS DISTINCT FROM current_user THEN
    RAISE EXCEPTION 'reviewer_not_authorized';
  END IF;

  IF current_setting('mithril.actor_id', true) IS DISTINCT FROM p_reviewer_id::text THEN
    RAISE EXCEPTION 'reviewer_not_authorized';
  END IF;

  IF NOT public.admin_cash_payout_recorder_is_allowed(p_reviewer_id) THEN
    RAISE EXCEPTION 'reviewer_not_authorized';
  END IF;

  IF p_decision IS DISTINCT FROM 'approve' AND p_decision IS DISTINCT FROM 'reject' THEN
    RAISE EXCEPTION 'invalid_decision';
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_review_notes, '')), '');
  IF v_notes IS NOT NULL AND length(v_notes) > 500 THEN
    RAISE EXCEPTION 'invalid_review_notes';
  END IF;

  SELECT *
  INTO v_row
  FROM public.worker_loan_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'request_not_found';
  END IF;

  IF v_row.status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'request_not_pending';
  END IF;

  IF p_decision = 'reject' THEN
    UPDATE public.worker_loan_requests
    SET
      status = 'rejected',
      reviewed_by = p_reviewer_id,
      review_notes = v_notes,
      reviewed_at = now(),
      updated_at = now()
    WHERE id = p_request_id;

    RETURN jsonb_build_object(
      'id', v_row.id,
      'workerId', v_row.worker_id,
      'amountMinor', v_row.amount_minor,
      'status', 'rejected',
      'outstandingMinor', COALESCE((
        SELECT a.outstanding_minor FROM public.worker_loan_accounts a WHERE a.worker_id = v_row.worker_id
      ), 0)
    );
  END IF;

  -- Eligibility must still hold when the request is approved, not just when submitted.
  PERFORM 1 FROM public.cleaner_data cd
  WHERE cd.user_id = v_row.worker_id AND cd.status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  -- Approve: credit wallet and record outstanding loan.
  SELECT w.id, COALESCE(w.balance_subunit, 0), COALESCE(w.currency, 'GHS')
  INTO v_wallet_id, v_balance, v_currency
  FROM public.wallets w
  WHERE w.user_id = v_row.worker_id
  FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance_subunit, currency)
    VALUES (v_row.worker_id, 0, 'GHS')
    ON CONFLICT (user_id) DO NOTHING;

    SELECT w.id, COALESCE(w.balance_subunit, 0), COALESCE(w.currency, 'GHS')
    INTO v_wallet_id, v_balance, v_currency
    FROM public.wallets w
    WHERE w.user_id = v_row.worker_id
    FOR UPDATE;
  END IF;

  IF v_wallet_id IS NULL THEN
    RAISE EXCEPTION 'wallet_not_found';
  END IF;

  IF v_currency IS DISTINCT FROM 'GHS' THEN
    RAISE EXCEPTION 'unsupported_currency';
  END IF;

  IF v_balance > 2147483647 - v_row.amount_minor THEN
    RAISE EXCEPTION 'amount_too_large';
  END IF;

  v_description := 'Loan advance';
  IF v_row.reason IS NOT NULL THEN
    v_description := v_description || ' — ' || left(v_row.reason, 120);
  END IF;

  UPDATE public.wallets
  SET balance_subunit = v_balance + v_row.amount_minor, updated_at = now()
  WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (wallet_id, booking_id, amount_subunit, type, description)
  VALUES (v_wallet_id, NULL, v_row.amount_minor, 'credit', v_description)
  RETURNING id INTO v_tx_id;

  INSERT INTO public.worker_loan_accounts (worker_id, outstanding_minor, currency)
  VALUES (v_row.worker_id, v_row.amount_minor, 'GHS')
  ON CONFLICT (worker_id) DO UPDATE
  SET
    outstanding_minor = public.worker_loan_accounts.outstanding_minor + EXCLUDED.outstanding_minor,
    updated_at = now()
  RETURNING outstanding_minor INTO v_outstanding;

  INSERT INTO public.worker_loan_events (
    worker_id, request_id, event_type, amount_minor, outstanding_after_minor,
    wallet_transaction_id, recorded_by, notes
  ) VALUES (
    v_row.worker_id, v_row.id, 'disbursement', v_row.amount_minor, v_outstanding,
    v_tx_id, p_reviewer_id, v_notes
  )
  RETURNING id INTO v_event_id;

  UPDATE public.worker_loan_requests
  SET
    status = 'approved',
    reviewed_by = p_reviewer_id,
    review_notes = v_notes,
    reviewed_at = now(),
    wallet_transaction_id = v_tx_id,
    updated_at = now()
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'workerId', v_row.worker_id,
    'amountMinor', v_row.amount_minor,
    'status', 'approved',
    'newBalanceMinor', v_balance + v_row.amount_minor,
    'outstandingMinor', v_outstanding,
    'walletTransactionId', v_tx_id,
    'loanEventId', v_event_id
  );
END;
$function$;

COMMENT ON FUNCTION public.create_worker_loan_request(uuid, integer, text) IS
  'Worker submits a pending loan/advance request. One pending request per worker.';

COMMENT ON FUNCTION public.review_worker_loan_request(uuid, uuid, text, text) IS
  'Admin approves (wallet credit + outstanding) or rejects a pending loan request.';
