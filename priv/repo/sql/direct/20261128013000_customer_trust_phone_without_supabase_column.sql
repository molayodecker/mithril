-- Paid booking updates call sync_customer_trust_verification_flags.
-- Supabase auth.users has phone_confirmed_at. Mithril auth.users does not,
-- and a static reference aborts the payment update.

CREATE OR REPLACE FUNCTION public.sync_customer_trust_verification_flags(p_customer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_phone_verified boolean := false;
  v_id_verified boolean := false;
  v_has_phone_confirmed_at boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'phone_confirmed_at'
  )
  INTO v_has_phone_confirmed_at;

  IF v_has_phone_confirmed_at THEN
    EXECUTE $sql$
      SELECT EXISTS (
        SELECT 1
        FROM auth.users au
        WHERE au.id = $1
          AND (
            au.phone_confirmed_at IS NOT NULL
            OR NULLIF(btrim(COALESCE(au.phone, '')), '') IS NOT NULL
          )
      )
    $sql$
    INTO v_phone_verified
    USING p_customer_id;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM auth.users au
      WHERE au.id = p_customer_id
        AND NULLIF(btrim(COALESCE(au.phone, '')), '') IS NOT NULL
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = p_customer_id
        AND NULLIF(btrim(COALESCE(u.phone, '')), '') IS NOT NULL
    )
    INTO v_phone_verified;
  END IF;

  -- Identity verification is user-level. A user who completes KYC as a cleaner
  -- is considered id_verified for customer booking trust decisions as well.
  SELECT EXISTS (
    SELECT 1
    FROM public.kyc_profiles kp
    WHERE kp.user_id = p_customer_id
      AND kp.kyc_status IN ('approved', 'completed')
  )
  INTO v_id_verified;

  INSERT INTO public.customer_trust_profiles (customer_id, phone_verified, id_verified)
  VALUES (p_customer_id, v_phone_verified, v_id_verified)
  ON CONFLICT (customer_id) DO UPDATE
  SET
    phone_verified = EXCLUDED.phone_verified,
    id_verified = EXCLUDED.id_verified,
    updated_at = now();
END;
$function$;
