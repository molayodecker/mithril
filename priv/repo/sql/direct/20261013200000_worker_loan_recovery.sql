-- Apply outstanding loan balance against a gross payout (recovery reduces net paid).

CREATE OR REPLACE FUNCTION public.apply_worker_loan_recovery(
  p_worker_id uuid,
  p_gross_minor integer,
  p_recorded_by uuid,
  p_source_type text,
  p_source_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_outstanding integer := 0;
  v_recovery integer;
  v_net integer;
  v_after integer;
  v_event_id uuid;
BEGIN
  IF p_worker_id IS NULL OR p_recorded_by IS NULL OR p_gross_minor IS NULL THEN
    RAISE EXCEPTION 'missing_required_fields';
  END IF;

  IF p_gross_minor <= 0 OR p_gross_minor > 2147483647 THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  IF session_user IS DISTINCT FROM current_user THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF current_setting('mithril.actor_id', true) IS DISTINCT FROM p_recorded_by::text THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT public.admin_cash_payout_recorder_is_allowed(p_recorded_by) THEN
    RAISE EXCEPTION 'recorded_by_not_authorized';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.cleaner_data cd WHERE cd.user_id = p_worker_id) THEN
    RAISE EXCEPTION 'worker_not_found';
  END IF;

  SELECT COALESCE(a.outstanding_minor, 0)
  INTO v_outstanding
  FROM public.worker_loan_accounts a
  WHERE a.worker_id = p_worker_id
  FOR UPDATE;

  v_recovery := LEAST(COALESCE(v_outstanding, 0), p_gross_minor);
  v_net := p_gross_minor - v_recovery;

  IF v_recovery > 0 THEN
    UPDATE public.worker_loan_accounts
    SET outstanding_minor = outstanding_minor - v_recovery, updated_at = now()
    WHERE worker_id = p_worker_id
    RETURNING outstanding_minor INTO v_after;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'loan_account_not_found';
    END IF;

    INSERT INTO public.worker_loan_events (
      worker_id, request_id, event_type, amount_minor, outstanding_after_minor,
      wallet_transaction_id, recorded_by, notes
    ) VALUES (
      p_worker_id,
      NULL,
      'repayment',
      v_recovery,
      v_after,
      NULL,
      p_recorded_by,
      left(COALESCE(p_source_type, 'payout') || ':' || COALESCE(p_source_id::text, ''), 500)
    )
    RETURNING id INTO v_event_id;
  ELSE
    v_after := COALESCE(v_outstanding, 0);
  END IF;

  RETURN jsonb_build_object(
    'grossMinor', p_gross_minor,
    'recoveryMinor', v_recovery,
    'netMinor', v_net,
    'outstandingMinor', v_after,
    'loanEventId', v_event_id
  );
END;
$function$;

COMMENT ON FUNCTION public.apply_worker_loan_recovery(uuid, integer, uuid, text, uuid) IS
  'Reduces outstanding loan balance by up to the gross payout amount. Returns net amount to pay after recovery.';
