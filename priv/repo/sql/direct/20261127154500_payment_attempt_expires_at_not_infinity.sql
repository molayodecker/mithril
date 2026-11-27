-- Give ready Stripe attempts 24 hours from the first successful preparation.
-- Keep legacy infinity values out of Postgrex results.

ALTER TABLE public.payment_attempts
  ALTER COLUMN expires_at DROP NOT NULL;

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
    -- Stripe may have created the intent while a concurrent reschedule
    -- invalidated this attempt. Keep its ID so the webhook can find the
    -- stale attempt and refund a late successful charge.
    IF v_attempt.stripe_payment_intent_id IS NOT NULL
       AND v_attempt.stripe_payment_intent_id <> v_payment_intent_id THEN
      RAISE EXCEPTION 'payment intent does not match existing attempt'
        USING ERRCODE = '22023';
    END IF;

    UPDATE public.payment_attempts pa
    SET stripe_payment_intent_id = v_payment_intent_id,
        updated_at = now()
    WHERE pa.id = p_attempt_id
    RETURNING * INTO v_attempt;

    state := v_attempt.status;
    reference := v_attempt.reference;
    stripe_payment_intent_id := v_attempt.stripe_payment_intent_id;
    stripe_client_secret := NULL;
    payment_status := v_payment_status;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_attempt.status = 'ready' AND v_attempt.expires_at <= now() THEN
    state := 'checkout_expired';
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
    expires_at = coalesce(pa.ready_at, now()) + interval '24 hours',
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

-- %%

UPDATE public.payment_attempts
SET expires_at = CASE
      WHEN provider = 'stripe' AND status = 'ready'
        THEN coalesce(ready_at, updated_at, created_at) + interval '24 hours'
      ELSE NULL
    END,
    ready_at = CASE
      WHEN provider = 'stripe' AND status = 'ready'
        THEN coalesce(ready_at, updated_at, created_at)
      ELSE ready_at
    END,
    updated_at = now()
WHERE expires_at = 'infinity'::timestamptz
   OR (provider = 'stripe' AND status = 'ready' AND expires_at IS NULL);
