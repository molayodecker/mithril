-- Accra Pet Care list-price checkout (sitting, walking, feeding/check-ins).
-- Listed visit amounts are the customer payable package (no platform fee stacked on top).
-- Platform fee is an internal earnings split of the payable total.
--
-- This does not replace assert_care_pet_service_bookable. That gate still decides
-- whether caregiving and pet care bookings can be created.

BEGIN;

INSERT INTO public.booking_settings (key, value_numeric, description)
VALUES
  (
    'pet_care_sitting_hours_2_major',
    70,
    'Pet Sitting 2-hour visit, major GHS'
  ),
  (
    'pet_care_sitting_hours_4_major',
    100,
    'Pet Sitting 4-hour visit, major GHS'
  ),
  (
    'pet_care_sitting_hours_8_major',
    150,
    'Pet Sitting 8-hour visit, major GHS'
  ),
  (
    'pet_care_sitting_overnight_major',
    200,
    'Pet Sitting overnight visit, major GHS'
  ),
  (
    'pet_care_sitting_hours_24_major',
    250,
    'Pet Sitting 24-hour visit, major GHS'
  ),
  (
    'pet_care_walk_min_30_major',
    50,
    'Dog Walking 30-minute visit, major GHS'
  ),
  (
    'pet_care_walk_min_60_major',
    80,
    'Dog Walking 60-minute visit, major GHS'
  ),
  (
    'pet_care_checkin_major',
    50,
    'Feeding / Check-in 30-minute visit, major GHS'
  ),
  (
    'pet_care_extra_major',
    25,
    'Pet Care extra pet, puppy/kitten attention, or medication, major GHS'
  ),
  (
    'pet_care_min_custom_visit_major',
    50,
    'Minimum negotiable Pet Care visit budget, major GHS'
  ),
  (
    'pet_care_weekly_discount_bps',
    500,
    'Discount for weekly Pet Care (basis points; 500 = 5%)'
  ),
  (
    'pet_care_monthly_discount_bps',
    1000,
    'Discount for monthly Pet Care (basis points; 1000 = 10%)'
  )
ON CONFLICT (key) DO UPDATE
SET
  description = EXCLUDED.description;

DROP FUNCTION IF EXISTS public.compute_pet_care_pricing(
  integer, text, integer, date, text, numeric, integer, boolean, boolean
);

CREATE FUNCTION public.compute_pet_care_pricing(
  p_service_id integer,
  p_care_package text,
  p_pet_count integer,
  p_scheduled_date date,
  p_frequency text,
  p_custom_visit_major numeric DEFAULT NULL,
  p_selected_day_count integer DEFAULT NULL,
  p_extra_attention boolean DEFAULT false,
  p_medication_required boolean DEFAULT false
)
RETURNS TABLE (
  pricing_version text,
  currency text,
  care_package text,
  pet_count integer,
  duration_hours numeric,
  work_rate_ghs_per_hour numeric,
  base_visit_major numeric,
  extras_surcharge_visit_major numeric,
  visit_major numeric,
  billable_days integer,
  subtotal_major numeric,
  frequency_discount_bps integer,
  frequency_discount_major numeric,
  subtotal_labor_major numeric,
  platform_fee_major numeric,
  booking_cover_major numeric,
  core_amount_minor integer,
  same_day_surcharge_bps integer,
  weekend_surcharge_bps integer,
  recurring_weekly_discount_bps integer,
  recurring_monthly_discount_bps integer,
  same_day_surcharge_minor integer,
  weekend_surcharge_minor integer,
  recurring_discount_minor integer,
  final_amount_minor integer,
  recurring_amount_minor integer,
  first_charge_amount_minor integer,
  discount_rate_bps integer,
  is_same_day boolean,
  is_weekend boolean,
  minimum_duration_hours numeric,
  cleaner_earnings_minor integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_default_platform_fee_bps constant integer := 1500;
  v_specialty text;
  v_service_active boolean;
  v_package text;
  v_frequency text;
  v_pet_count integer;
  v_extra_major numeric;
  v_min_custom numeric;
  v_weekly_bps integer;
  v_monthly_bps integer;
  v_base_visit numeric;
  v_extras numeric;
  v_visit numeric;
  v_days integer;
  v_month_days integer;
  v_subtotal_major numeric;
  v_discount_bps integer;
  v_discount_major numeric;
  v_payable_major numeric;
  v_payable_minor integer;
  v_platform_bps integer;
  v_platform_fee_major numeric;
  v_duration numeric;
  v_settings_platform_raw numeric;
  v_cleaner_earnings_minor integer;
  v_setting numeric;
BEGIN
  IF p_scheduled_date IS NULL THEN
    RAISE EXCEPTION 'Choose a start date.';
  END IF;

  SELECT st.specialty_slug, COALESCE(st.active, true)
  INTO v_specialty, v_service_active
  FROM public.service_types st
  WHERE st.id = p_service_id;

  IF NOT FOUND OR v_service_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Invalid or inactive service';
  END IF;

  IF v_specialty NOT IN ('pet_sitting', 'dog_walking', 'feeding_checkins') THEN
    RAISE EXCEPTION 'Pet Care list prices apply to Pet Sitting, Dog Walking, and Feeding / Check-ins only.';
  END IF;

  v_package := lower(btrim(COALESCE(p_care_package, '')));
  v_frequency := lower(btrim(COALESCE(p_frequency, 'once')));
  IF v_frequency NOT IN ('once', 'daily', 'weekly', 'monthly', 'custom') THEN
    RAISE EXCEPTION 'Choose how often you need this care.';
  END IF;

  v_pet_count := GREATEST(1, COALESCE(p_pet_count, 1));

  SELECT bs.value_numeric INTO v_weekly_bps
  FROM public.booking_settings bs
  WHERE bs.key = 'pet_care_weekly_discount_bps';
  SELECT bs.value_numeric INTO v_monthly_bps
  FROM public.booking_settings bs
  WHERE bs.key = 'pet_care_monthly_discount_bps';
  SELECT bs.value_numeric INTO v_extra_major
  FROM public.booking_settings bs
  WHERE bs.key = 'pet_care_extra_major';
  SELECT bs.value_numeric INTO v_min_custom
  FROM public.booking_settings bs
  WHERE bs.key = 'pet_care_min_custom_visit_major';

  v_weekly_bps := GREATEST(0, LEAST(10000, COALESCE(v_weekly_bps, 500)::integer));
  v_monthly_bps := GREATEST(0, LEAST(10000, COALESCE(v_monthly_bps, 1000)::integer));
  v_extra_major := GREATEST(0, COALESCE(v_extra_major, 25));
  v_min_custom := GREATEST(0, COALESCE(v_min_custom, 50));

  IF v_specialty = 'pet_sitting' THEN
    IF v_package NOT IN ('hours_2', 'hours_4', 'hours_8', 'overnight', 'hours_24', 'custom') THEN
      RAISE EXCEPTION 'Choose how long you need care.';
    END IF;
    IF v_package = 'hours_2' THEN
      v_duration := 2;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_sitting_hours_2_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 70));
    ELSIF v_package = 'hours_4' THEN
      v_duration := 4;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_sitting_hours_4_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 100));
    ELSIF v_package = 'hours_8' THEN
      v_duration := 8;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_sitting_hours_8_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 150));
    ELSIF v_package = 'overnight' THEN
      v_duration := 12;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_sitting_overnight_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 200));
    ELSIF v_package = 'hours_24' THEN
      v_duration := 24;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_sitting_hours_24_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 250));
    ELSE
      v_duration := 8;
      IF p_custom_visit_major IS NULL
        OR p_custom_visit_major <> p_custom_visit_major
        OR p_custom_visit_major < v_min_custom THEN
        RAISE EXCEPTION 'Enter a visit budget of at least GH₵%.', v_min_custom;
      END IF;
      v_base_visit := round(p_custom_visit_major::numeric, 2);
    END IF;
  ELSIF v_specialty = 'dog_walking' THEN
    IF v_package NOT IN ('min_30', 'min_60', 'custom') THEN
      RAISE EXCEPTION 'Choose a 30 or 60 minute walk.';
    END IF;
    IF v_package = 'min_30' THEN
      v_duration := 0.5;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_walk_min_30_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 50));
    ELSIF v_package = 'min_60' THEN
      v_duration := 1;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_walk_min_60_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 80));
    ELSE
      v_duration := 1;
      IF p_custom_visit_major IS NULL
        OR p_custom_visit_major <> p_custom_visit_major
        OR p_custom_visit_major < v_min_custom THEN
        RAISE EXCEPTION 'Enter a visit budget of at least GH₵%.', v_min_custom;
      END IF;
      v_base_visit := round(p_custom_visit_major::numeric, 2);
    END IF;
  ELSE
    IF v_package NOT IN ('min_30', 'custom') THEN
      RAISE EXCEPTION 'Choose a check-in price.';
    END IF;
    IF v_package = 'min_30' THEN
      v_duration := 0.5;
      SELECT bs.value_numeric INTO v_setting FROM public.booking_settings bs
      WHERE bs.key = 'pet_care_checkin_major';
      v_base_visit := GREATEST(0, COALESCE(v_setting, 50));
    ELSE
      v_duration := 0.5;
      IF p_custom_visit_major IS NULL
        OR p_custom_visit_major <> p_custom_visit_major
        OR p_custom_visit_major < v_min_custom THEN
        RAISE EXCEPTION 'Enter a visit budget of at least GH₵%.', v_min_custom;
      END IF;
      v_base_visit := round(p_custom_visit_major::numeric, 2);
    END IF;
  END IF;

  v_extras := (v_pet_count - 1) * v_extra_major;
  IF COALESCE(p_extra_attention, false) THEN
    v_extras := v_extras + v_extra_major;
  END IF;
  IF COALESCE(p_medication_required, false) THEN
    v_extras := v_extras + v_extra_major;
  END IF;
  v_extras := round(v_extras::numeric, 2);
  v_visit := round((v_base_visit + v_extras)::numeric, 2);

  IF v_frequency = 'weekly' THEN
    v_days := GREATEST(1, LEAST(7, COALESCE(NULLIF(p_selected_day_count, 0), 7)));
    v_discount_bps := v_weekly_bps;
  ELSIF v_frequency = 'custom' THEN
    v_days := GREATEST(1, LEAST(7, COALESCE(NULLIF(p_selected_day_count, 0), 1)));
    v_discount_bps := CASE WHEN v_days = 7 THEN v_weekly_bps ELSE 0 END;
  ELSIF v_frequency = 'monthly' THEN
    v_month_days := EXTRACT(
      DAY FROM (date_trunc('month', p_scheduled_date) + INTERVAL '1 month - 1 day')
    )::integer;
    v_days := v_month_days;
    v_discount_bps := v_monthly_bps;
  ELSE
    v_days := 1;
    v_discount_bps := 0;
  END IF;

  v_subtotal_major := round((v_visit * v_days)::numeric, 2);
  v_discount_major := round((v_subtotal_major * v_discount_bps / 10000.0)::numeric, 2);
  v_payable_major := round((v_subtotal_major - v_discount_major)::numeric, 2);
  IF v_payable_major < 0 THEN
    v_payable_major := 0;
  END IF;
  v_payable_minor := round(v_payable_major * 100)::integer;

  SELECT bs.value_numeric INTO v_settings_platform_raw
  FROM public.booking_settings bs
  WHERE bs.key = 'platform_fee_percentage';

  IF v_settings_platform_raw IS NULL OR v_settings_platform_raw < 0 THEN
    v_platform_bps := c_default_platform_fee_bps;
  ELSIF v_settings_platform_raw <= 100 THEN
    v_platform_bps := round(v_settings_platform_raw * 100)::integer;
  ELSE
    v_platform_bps := round(v_settings_platform_raw)::integer;
  END IF;
  v_platform_bps := GREATEST(0, LEAST(10000, v_platform_bps));

  IF v_platform_bps <= 0 OR v_payable_minor <= 0 THEN
    v_platform_fee_major := 0;
  ELSE
    v_platform_fee_major := (round(v_payable_minor * v_platform_bps / 10000.0) / 100.0)::numeric;
  END IF;

  v_cleaner_earnings_minor := public.cleaner_earnings_subunit_from_booking(
    v_payable_minor,
    v_payable_major,
    v_platform_fee_major,
    false,
    0,
    v_payable_minor
  );

  RETURN QUERY
  SELECT
    'pet_care_v1'::text,
    'GHS'::text,
    v_package,
    v_pet_count,
    v_duration,
    CASE WHEN v_duration > 0 THEN round((v_visit / v_duration)::numeric, 2) ELSE 0 END,
    v_base_visit,
    v_extras,
    v_visit,
    v_days,
    v_subtotal_major,
    v_discount_bps,
    v_discount_major,
    v_payable_major,
    v_platform_fee_major,
    0::numeric,
    v_payable_minor,
    0,
    0,
    v_weekly_bps,
    v_monthly_bps,
    0,
    0,
    round(v_discount_major * 100)::integer,
    v_payable_minor,
    v_payable_minor,
    v_payable_minor,
    v_discount_bps,
    false,
    false,
    v_duration,
    v_cleaner_earnings_minor;
END;
$$;

COMMENT ON FUNCTION public.compute_pet_care_pricing(
  integer, text, integer, date, text, numeric, integer, boolean, boolean
) IS
  'Authoritative Pet Care list-price checkout. Weekly is 5% off selected days. Monthly is 10% off the calendar month. Platform fee is an earnings split, not an add-on.';

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.compute_pet_care_pricing(integer, text, integer, date, text, numeric, integer, boolean, boolean) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.compute_pet_care_pricing(integer, text, integer, date, text, numeric, integer, boolean, boolean) TO authenticated';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping pet care pricing grants: %', SQLERRM;
END $$;

COMMIT;
