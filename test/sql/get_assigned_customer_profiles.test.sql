-- Assigned cleaners can read a customer's name and avatar.
-- Other users, including the customer, cannot use this function to read that row.
-- Not applied by scripts/apply_direct_schema.sh.
--
--   psql "$TARGET_DATABASE_URL" -v ON_ERROR_STOP=1 -f test/sql/get_assigned_customer_profiles.test.sql

BEGIN;

DO $$
DECLARE
  v_customer uuid := 'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a101'::uuid;
  v_cleaner uuid := 'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b202'::uuid;
  v_direct uuid := 'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c303'::uuid;
  v_stranger uuid := 'd4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d404'::uuid;
  v_service_id integer;
  v_booking_id uuid := 'e5e5e5e5-e5e5-4e5e-8e5e-e5e5e5e5e505'::uuid;
  v_direct_booking_id uuid := 'f6f6f6f6-f6f6-4f6f-8f6f-f6f6f6f6f606'::uuid;
  v_loc_geog geography := ST_SetSRID(ST_MakePoint(-0.186964, 5.650562), 4326)::geography;
  v_start timestamptz := timestamptz '2099-12-01 10:00:00+00';
  v_name text;
  v_count integer;
BEGIN
  SELECT id INTO v_service_id
  FROM public.service_types
  WHERE active = true
  ORDER BY id
  LIMIT 1;

  IF v_service_id IS NULL THEN
    RAISE EXCEPTION 'get_assigned_customer_profiles.test.sql requires an active service';
  END IF;

  INSERT INTO auth.users (id, email, aud, role, email_confirmed_at)
  VALUES
    (v_customer, 'assigned-customer-profile@example.com', 'authenticated', 'authenticated', now()),
    (v_cleaner, 'assigned-customer-cleaner@example.com', 'authenticated', 'authenticated', now()),
    (v_direct, 'assigned-customer-direct@example.com', 'authenticated', 'authenticated', now()),
    (v_stranger, 'assigned-customer-stranger@example.com', 'authenticated', 'authenticated', now())
  ON CONFLICT (id) DO UPDATE SET email = excluded.email;

  INSERT INTO public.users (id, email, password_hash, phone)
  VALUES
    (v_customer, 'assigned-customer-profile@example.com', 'x', '+233200000401'),
    (v_cleaner, 'assigned-customer-cleaner@example.com', 'x', '+233200000402'),
    (v_direct, 'assigned-customer-direct@example.com', 'x', '+233200000403'),
    (v_stranger, 'assigned-customer-stranger@example.com', 'x', '+233200000404')
  ON CONFLICT (id) DO UPDATE
  SET email = excluded.email,
      phone = excluded.phone;

  INSERT INTO public.profiles (
    id, user_id, firstname, lastname, fullname, avatar_url, address, location_wkt, preferences
  )
  VALUES (
    v_customer,
    v_customer,
    'Ama',
    'Mensah',
    'Ama Mensah',
    'avatars/ama.png',
    'House 12, East Legon, Accra',
    v_loc_geog,
    '{"profile_visibility": false}'::jsonb
  )
  ON CONFLICT (id) DO UPDATE
    SET fullname = excluded.fullname,
        avatar_url = excluded.avatar_url,
        address = excluded.address,
        deleted_at = NULL,
        deactivated_at = NULL,
        deletion_status = 'none',
        preferences = excluded.preferences;

  INSERT INTO public.customer_trust_profiles (customer_id, phone_verified, id_verified, verification_required, risk_score)
  VALUES (v_customer, true, true, false, 0)
  ON CONFLICT (customer_id) DO UPDATE
    SET verification_required = false,
        updated_at = now();

  DELETE FROM public.bookings WHERE id IN (v_booking_id, v_direct_booking_id);

  INSERT INTO public.bookings (
    id, customer_id, cleaner_id, service_id, title, scheduled_date, scheduled_time,
    address, total_price, final_amount_minor, duration_hours, status, payment_status,
    booking_period, currency
  )
  VALUES (
    v_booking_id, v_customer, v_cleaner, v_service_id, 'Assigned customer profile',
    DATE '2099-12-01', TIME '10:00', 'Accra', 10000, 10000, 2, 'confirmed', 'paid',
    tstzrange(v_start, v_start + interval '2 hours', '[)'), 'GHS'
  );

  INSERT INTO public.bookings (
    id, customer_id, cleaner_id, direct_assigned_cleaner_id, service_id, title,
    scheduled_date, scheduled_time, address, total_price, final_amount_minor,
    duration_hours, status, payment_status, booking_period, currency
  )
  VALUES (
    v_direct_booking_id, v_customer, NULL, v_direct, v_service_id, 'Direct assigned customer profile',
    DATE '2099-12-02', TIME '10:00', 'Accra', 10000, 10000, 2, 'pending', 'pending',
    tstzrange(v_start + interval '1 day', v_start + interval '1 day 2 hours', '[)'), 'GHS'
  );

  PERFORM set_config('request.jwt.claim.sub', v_cleaner::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  SELECT profile_row.fullname
  INTO v_name
  FROM public.get_assigned_customer_profiles(ARRAY[v_customer]) AS profile_row;

  IF v_name IS DISTINCT FROM 'Ama Mensah' THEN
    RAISE EXCEPTION 'assigned cleaner should see the customer name, got %', v_name;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_stranger::text, true);
  SELECT count(*) INTO v_count
  FROM public.get_assigned_customer_profiles(ARRAY[v_customer]);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'unrelated user should not see the customer profile';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_customer::text, true);
  SELECT count(*) INTO v_count
  FROM public.get_assigned_customer_profiles(ARRAY[v_customer]);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'the customer should not read their own row through the cleaner function';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_direct::text, true);
  SELECT profile_row.fullname
  INTO v_name
  FROM public.get_assigned_customer_profiles(ARRAY[v_customer]) AS profile_row;
  IF v_name IS DISTINCT FROM 'Ama Mensah' THEN
    RAISE EXCEPTION 'direct-assigned cleaner should see the customer name, got %', v_name;
  END IF;

  UPDATE public.profiles SET deleted_at = now() WHERE id = v_customer;
  SELECT count(*) INTO v_count
  FROM public.get_assigned_customer_profiles(ARRAY[v_customer]);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'deleted customer profile should stay hidden';
  END IF;

  DELETE FROM public.bookings WHERE id IN (v_booking_id, v_direct_booking_id);
END $$;

ROLLBACK;
