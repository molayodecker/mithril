-- Card and Apple Pay reserve a Stripe attempt. The Paystack function stays the
-- 4-argument overload and still inserts provider 'paystack'.
-- Replay-safe: columns, checks, and both functions can be applied again.
-- Lines containing only `-- %%` are comments. They also split statements for
-- a one-statement SQL runner. psql ignores them.

ALTER TABLE public.payment_attempts
  ADD COLUMN IF NOT EXISTS stripe_payment_intent_id text,
  ADD COLUMN IF NOT EXISTS stripe_client_secret text;

-- %%

ALTER TABLE public.payment_attempts
  DROP CONSTRAINT IF EXISTS payment_attempts_provider_check;

-- %%

ALTER TABLE public.payment_attempts
  ADD CONSTRAINT payment_attempts_provider_check
  CHECK (provider IN ('paystack', 'stripe'));

-- %%

ALTER TABLE public.payment_attempts
  DROP CONSTRAINT IF EXISTS payment_attempts_ready_url_check;

-- %%

ALTER TABLE public.payment_attempts
  ADD CONSTRAINT payment_attempts_ready_url_check
  CHECK (
    status <> 'ready'
    OR (provider = 'paystack' AND authorization_url IS NOT NULL)
    OR (provider = 'stripe' AND stripe_client_secret IS NOT NULL)
  );

-- %%

CREATE UNIQUE INDEX IF NOT EXISTS payment_attempts_stripe_payment_intent_idx
  ON public.payment_attempts (stripe_payment_intent_id)
  WHERE stripe_payment_intent_id IS NOT NULL;

-- %%

CREATE OR REPLACE FUNCTION public.reserve_booking_payment_attempt(
  p_booking_id uuid,
  p_request_fingerprint text,
  p_amount_minor bigint,
  p_currency text,
  p_provider text
)
RETURNS TABLE(
  attempt_id uuid,
  created boolean,
  state text,
  reference text,
  authorization_url text,
  access_code text,
  payment_status text,
  expires_at timestamp with time zone,
  amount_minor bigint,
  currency text,
  request_fingerprint text,
  provider text,
  stripe_payment_intent_id text,
  stripe_client_secret text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_customer_id uuid;
  v_payment_status text;
  v_booking_reference text;
  v_fingerprint text := NULLIF(btrim(p_request_fingerprint), '');
  v_currency text := upper(NULLIF(btrim(p_currency), ''));
  v_provider text := lower(NULLIF(btrim(p_provider), ''));
  v_attempt public.payment_attempts%ROWTYPE;
  v_new_attempt_id uuid;
  v_new_reference text;
  v_state text;
  v_created boolean := false;
  v_show_secret boolean := false;
BEGIN
  IF v_provider IS DISTINCT FROM 'stripe' THEN
    RAISE EXCEPTION 'stripe reserve requires provider stripe'
      USING ERRCODE = '22023';
  END IF;

  IF p_booking_id IS NULL OR v_fingerprint IS NULL THEN
    RAISE EXCEPTION 'booking_id and request_fingerprint are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_amount_minor IS NULL OR p_amount_minor <= 0 OR v_currency IS NULL THEN
    RAISE EXCEPTION 'amount_minor and currency must be valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT b.customer_id, b.payment_status, b.reference
  INTO v_customer_id, v_payment_status, v_booking_reference
  FROM public.bookings b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> v_customer_id THEN
    RAISE EXCEPTION 'not authorized'
      USING ERRCODE = '42501';
  END IF;

  IF lower(coalesce(v_payment_status, '')) IN (
    'paid', 'post_paid', 'refunded', 'partially_refunded'
  ) THEN
    attempt_id := NULL;
    created := false;
    state := 'settled';
    reference := v_booking_reference;
    authorization_url := NULL;
    access_code := NULL;
    payment_status := v_payment_status;
    expires_at := NULL;
    amount_minor := NULL;
    currency := NULL;
    request_fingerprint := NULL;
    provider := NULL;
    stripe_payment_intent_id := NULL;
    stripe_client_secret := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT pa.*
  INTO v_attempt
  FROM public.payment_attempts pa
  WHERE pa.booking_id = p_booking_id
    AND pa.status IN ('initializing', 'ready')
  ORDER BY pa.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND v_attempt.provider IS DISTINCT FROM 'stripe' THEN
    IF v_attempt.status = 'initializing' AND v_attempt.expires_at <= now() THEN
      UPDATE public.payment_attempts
      SET
        status = 'expired',
        failed_at = coalesce(failed_at, now()),
        updated_at = now()
      WHERE id = v_attempt.id
        AND status = 'initializing';
    ELSE
      v_state := 'conflict';
    END IF;
  ELSIF FOUND AND v_attempt.status = 'initializing' AND v_attempt.expires_at <= now() THEN
    v_state := 'stale';
    v_show_secret := true;
  ELSIF FOUND
    AND v_attempt.request_fingerprint = v_fingerprint
    AND v_attempt.amount_minor = p_amount_minor
    AND v_attempt.currency = v_currency THEN
    v_state := v_attempt.status;
    v_show_secret := true;
  ELSIF FOUND THEN
    v_state := 'conflict';
  END IF;

  IF v_state IS NULL THEN
    v_new_attempt_id := gen_random_uuid();
    v_new_reference := format(
      'BK-%s-%s',
      p_booking_id::text,
      left(replace(v_new_attempt_id::text, '-', ''), 16)
    );

    INSERT INTO public.payment_attempts (
      id,
      booking_id,
      provider,
      reference,
      request_fingerprint,
      status,
      amount_minor,
      currency,
      expires_at
    ) VALUES (
      v_new_attempt_id,
      p_booking_id,
      'stripe',
      v_new_reference,
      v_fingerprint,
      'initializing',
      p_amount_minor,
      v_currency,
      now() + interval '5 minutes'
    )
    RETURNING * INTO v_attempt;

    UPDATE public.bookings b
    SET reference = v_attempt.reference, updated_at = now()
    WHERE b.id = p_booking_id
      AND lower(coalesce(b.payment_status, '')) NOT IN (
        'paid', 'post_paid', 'refunded', 'partially_refunded'
      );

    v_state := v_attempt.status;
    v_created := true;
  END IF;

  attempt_id := v_attempt.id;
  created := v_created;
  state := v_state;
  reference := v_attempt.reference;
  authorization_url := v_attempt.authorization_url;
  access_code := v_attempt.access_code;
  payment_status := v_payment_status;
  expires_at := v_attempt.expires_at;
  amount_minor := v_attempt.amount_minor;
  currency := v_attempt.currency;
  request_fingerprint := v_attempt.request_fingerprint;
  provider := v_attempt.provider;
  stripe_payment_intent_id := v_attempt.stripe_payment_intent_id;
  stripe_client_secret := CASE
    WHEN v_show_secret THEN v_attempt.stripe_client_secret
    ELSE NULL
  END;
  RETURN NEXT;
END;
$function$;

-- %%

CREATE OR REPLACE FUNCTION public.complete_stripe_booking_payment_attempt(
  p_attempt_id uuid,
  p_payment_intent_id text,
  p_client_secret text,
  p_reference text
)
RETURNS TABLE(
  state text,
  reference text,
  stripe_payment_intent_id text,
  stripe_client_secret text,
  payment_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_attempt public.payment_attempts%ROWTYPE;
  v_booking_id uuid;
  v_customer_id uuid;
  v_payment_status text;
  v_booking_reference text;
  v_payment_intent_id text := NULLIF(btrim(p_payment_intent_id), '');
  v_client_secret text := NULLIF(btrim(p_client_secret), '');
  v_reference text := NULLIF(btrim(p_reference), '');
BEGIN
  IF p_attempt_id IS NULL OR v_payment_intent_id IS NULL OR v_client_secret IS NULL THEN
    RAISE EXCEPTION 'attempt_id, payment_intent_id, and client_secret are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pa.booking_id
  INTO v_booking_id
  FROM public.payment_attempts pa
  WHERE pa.id = p_attempt_id
    AND pa.provider = 'stripe';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT b.customer_id, b.payment_status, b.reference
  INTO v_customer_id, v_payment_status, v_booking_reference
  FROM public.bookings b
  WHERE b.id = v_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_attempt
  FROM public.payment_attempts
  WHERE id = p_attempt_id
    AND provider = 'stripe'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> v_customer_id THEN
    RAISE EXCEPTION 'not authorized'
      USING ERRCODE = '42501';
  END IF;

  IF v_reference IS NOT NULL AND v_reference <> v_attempt.reference THEN
    RAISE EXCEPTION 'provider reference does not match reserved reference'
      USING ERRCODE = '22023';
  END IF;

  IF lower(coalesce(v_payment_status, '')) IN (
    'paid', 'post_paid', 'refunded', 'partially_refunded'
  ) THEN
    state := 'settled';
    reference := v_booking_reference;
    stripe_payment_intent_id := v_attempt.stripe_payment_intent_id;
    stripe_client_secret := NULL;
    payment_status := v_payment_status;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_attempt.status NOT IN ('initializing', 'ready') THEN
    state := v_attempt.status;
    reference := v_attempt.reference;
    stripe_payment_intent_id := v_attempt.stripe_payment_intent_id;
    stripe_client_secret := NULL;
    payment_status := v_payment_status;
    RETURN NEXT;
    RETURN;
  END IF;

  UPDATE public.payment_attempts pa
  SET
    status = 'ready',
    stripe_payment_intent_id = v_payment_intent_id,
    stripe_client_secret = v_client_secret,
    ready_at = coalesce(pa.ready_at, now()),
    expires_at = 'infinity'::timestamptz,
    updated_at = now()
  WHERE pa.id = p_attempt_id
  RETURNING * INTO v_attempt;

  UPDATE public.bookings b
  SET reference = v_attempt.reference, updated_at = now()
  WHERE b.id = v_attempt.booking_id
    AND lower(coalesce(b.payment_status, '')) NOT IN (
      'paid', 'post_paid', 'refunded', 'partially_refunded'
    );

  state := 'ready';
  reference := v_attempt.reference;
  stripe_payment_intent_id := v_attempt.stripe_payment_intent_id;
  stripe_client_secret := v_attempt.stripe_client_secret;
  payment_status := v_payment_status;
  RETURN NEXT;
END;
$function$;
