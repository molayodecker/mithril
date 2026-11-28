-- Monthly Family Care is a fixed package fee for Monday–Friday in the start
-- month. Weekend days selected by the customer are extra, at the daily rate.
-- Single-day, weekly, and custom pricing stay on the daily rate.
--
-- Monthly package fees (major GHS):
--   family_care_child_half_day_monthly_major        1700
--   family_care_child_full_day_monthly_major        2500
--   family_care_child_experienced_monthly_major     3000
--   family_care_senior_half_day_monthly_major       2000
--   family_care_senior_full_day_monthly_major       3000

BEGIN;

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS family_care_schedule jsonb;

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS billing_period_start date;

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS covered_by_booking_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS bookings_family_care_period_visit_uidx
  ON public.bookings (subscription_id, billing_period_start, scheduled_date)
  WHERE billing_period_start IS NOT NULL
    AND status <> 'cancelled';

INSERT INTO public.booking_settings (key, value_numeric, description)
VALUES
  (
    'family_care_child_half_day_monthly_major',
    1700,
    'Child Care half-day monthly package (Monday–Friday), major GHS'
  ),
  (
    'family_care_child_full_day_monthly_major',
    2500,
    'Child Care full-day monthly package (Monday–Friday), major GHS'
  ),
  (
    'family_care_child_experienced_monthly_major',
    3000,
    'Experienced Child Care monthly package (Monday–Friday), major GHS'
  ),
  (
    'family_care_senior_half_day_monthly_major',
    2000,
    'Senior Care half-day monthly package (Monday–Friday), major GHS'
  ),
  (
    'family_care_senior_full_day_monthly_major',
    3000,
    'Senior Care full-day monthly package (Monday–Friday), major GHS'
  )
ON CONFLICT (key) DO UPDATE
SET
  value_numeric = EXCLUDED.value_numeric,
  description = EXCLUDED.description;

INSERT INTO public.booking_settings (key, value_numeric, description)
VALUES
  (
    'family_care_child_half_day_major',
    100,
    'Child Care half-day package (up to 4 hours), major GHS'
  ),
  (
    'family_care_child_full_day_major',
    150,
    'Child Care full-day package (up to 8 hours), major GHS'
  ),
  (
    'family_care_child_experienced_major',
    180,
    'Child Care experienced / CPR-trained nanny package (up to 8 hours), major GHS'
  ),
  (
    'family_care_child_min_daily_major',
    100,
    'Minimum negotiable Child Care daily budget, major GHS'
  ),
  (
    'family_care_child_second_surcharge_major',
    25,
    'Added to the Child Care daily package for a second child, major GHS'
  ),
  (
    'family_care_child_third_surcharge_major',
    50,
    'Added to the Child Care daily package for a third child, major GHS'
  ),
  (
    'family_care_senior_half_day_major',
    120,
    'Senior Care half-day package (up to 4 hours), major GHS'
  ),
  (
    'family_care_senior_full_day_major',
    180,
    'Senior Care full-day package (up to 8 hours), major GHS'
  ),
  (
    'family_care_senior_mobility_major',
    30,
    'Senior Care mobility assistance add-on per day, major GHS'
  ),
  (
    'family_care_senior_errands_major',
    20,
    'Senior Care errands add-on per day, major GHS'
  ),
  (
    'family_care_senior_appointments_major',
    30,
    'Senior Care appointment accompaniment add-on per day, major GHS'
  ),
  (
    'family_care_weekly_discount_bps',
    500,
    'Discount when billing 7 Family Care days (basis points; 500 = 5%)'
  ),
  (
    'family_care_monthly_discount_bps',
    1000,
    'Retired. Monthly Family Care uses the fixed package fee, not this percent-off.'
  )
ON CONFLICT (key) DO UPDATE
SET
  description = EXCLUDED.description;

DROP FUNCTION IF EXISTS public.compute_family_care_pricing(integer, text, integer, date, text, numeric, integer);
DROP FUNCTION IF EXISTS public.compute_family_care_pricing(
  integer, text, integer, date, text, numeric, integer, boolean, boolean, boolean
);
DROP FUNCTION IF EXISTS public.compute_family_care_pricing(
  integer, text, integer, date, text, numeric, integer, boolean, boolean, boolean, text[]
);

CREATE FUNCTION public.compute_family_care_pricing(
  p_service_id integer,
  p_care_package text,
  p_child_count integer,
  p_scheduled_date date,
  p_frequency text,
  p_custom_daily_major numeric DEFAULT NULL,
  p_selected_day_count integer DEFAULT NULL,
  p_mobility boolean DEFAULT false,
  p_errands boolean DEFAULT false,
  p_appointments boolean DEFAULT false,
  p_weekdays text[] DEFAULT NULL
)
RETURNS TABLE (
  pricing_version text,
  currency text,
  care_package text,
  child_count integer,
  duration_hours numeric,
  work_rate_ghs_per_hour numeric,
  base_daily_major numeric,
  children_surcharge_daily_major numeric,
  extras_surcharge_daily_major numeric,
  daily_major numeric,
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
  c_half_hours constant numeric := 4;
  c_full_hours constant numeric := 8;
  c_default_platform_fee_bps constant integer := 1500;
  v_specialty text;
  v_service_active boolean;
  v_is_senior boolean;
  v_package text;
  v_frequency text;
  v_child_count integer;
  v_half_day numeric;
  v_full_day numeric;
  v_experienced numeric;
  v_min_daily numeric;
  v_second numeric;
  v_third numeric;
  v_mobility_major numeric;
  v_errands_major numeric;
  v_appointments_major numeric;
  v_weekly_bps integer;
  v_monthly_bps integer;
  v_base_daily numeric;
  v_child_surcharge numeric;
  v_extras numeric;
  v_daily numeric;
  v_days integer;
  v_month_end date;
  v_weekday_visits integer;
  v_weekend_visits integer;
  v_monthly_fee numeric;
  v_weekend_major numeric;
  v_weekend_minor integer;
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

  PERFORM public.assert_care_pet_service_bookable(p_service_id);

  v_is_senior := v_specialty = 'senior_care';
  IF v_specialty IS DISTINCT FROM 'child_care' AND NOT v_is_senior THEN
    RAISE EXCEPTION 'Family Care day rates apply to Child Care and Senior Care only.';
  END IF;

  v_package := lower(btrim(COALESCE(p_care_package, '')));
  IF v_is_senior THEN
    IF v_package NOT IN ('half_day', 'full_day') THEN
      RAISE EXCEPTION 'Choose half day or full day.';
    END IF;
  ELSIF v_package NOT IN ('half_day', 'full_day', 'experienced', 'negotiable') THEN
    RAISE EXCEPTION 'Choose half day, full day, experienced, or a custom daily budget.';
  END IF;

  v_frequency := lower(btrim(COALESCE(p_frequency, 'once')));
  IF v_frequency NOT IN ('once', 'daily', 'weekly', 'monthly', 'custom') THEN
    RAISE EXCEPTION 'Choose how often you need this care.';
  END IF;

  v_child_count := GREATEST(1, COALESCE(p_child_count, 1));

  SELECT bs.value_numeric INTO v_weekly_bps
  FROM public.booking_settings bs
  WHERE bs.key = 'family_care_weekly_discount_bps';
  SELECT bs.value_numeric INTO v_monthly_bps
  FROM public.booking_settings bs
  WHERE bs.key = 'family_care_monthly_discount_bps';
  v_weekly_bps := GREATEST(0, LEAST(10000, COALESCE(v_weekly_bps, 500)::integer));
  v_monthly_bps := GREATEST(0, LEAST(10000, COALESCE(v_monthly_bps, 1000)::integer));

  IF v_is_senior THEN
    SELECT bs.value_numeric INTO v_half_day
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_senior_half_day_major';
    SELECT bs.value_numeric INTO v_full_day
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_senior_full_day_major';
    SELECT bs.value_numeric INTO v_mobility_major
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_senior_mobility_major';
    SELECT bs.value_numeric INTO v_errands_major
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_senior_errands_major';
    SELECT bs.value_numeric INTO v_appointments_major
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_senior_appointments_major';

    v_half_day := GREATEST(0, COALESCE(v_half_day, 120));
    v_full_day := GREATEST(0, COALESCE(v_full_day, 180));
    v_mobility_major := GREATEST(0, COALESCE(v_mobility_major, 30));
    v_errands_major := GREATEST(0, COALESCE(v_errands_major, 20));
    v_appointments_major := GREATEST(0, COALESCE(v_appointments_major, 30));

    IF v_package = 'half_day' THEN
      v_duration := c_half_hours;
      v_base_daily := v_half_day;
    ELSE
      v_duration := c_full_hours;
      v_base_daily := v_full_day;
    END IF;

    v_child_surcharge := 0;
    v_extras := 0;
    IF COALESCE(p_mobility, false) THEN
      v_extras := v_extras + v_mobility_major;
    END IF;
    IF COALESCE(p_errands, false) THEN
      v_extras := v_extras + v_errands_major;
    END IF;
    IF COALESCE(p_appointments, false) THEN
      v_extras := v_extras + v_appointments_major;
    END IF;
    v_extras := round(v_extras::numeric, 2);
    v_daily := round((v_base_daily + v_extras)::numeric, 2);
  ELSE
    SELECT bs.value_numeric INTO v_half_day
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_child_half_day_major';
    SELECT bs.value_numeric INTO v_full_day
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_child_full_day_major';
    SELECT bs.value_numeric INTO v_experienced
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_child_experienced_major';
    SELECT bs.value_numeric INTO v_min_daily
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_child_min_daily_major';
    SELECT bs.value_numeric INTO v_second
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_child_second_surcharge_major';
    SELECT bs.value_numeric INTO v_third
    FROM public.booking_settings bs
    WHERE bs.key = 'family_care_child_third_surcharge_major';

    v_half_day := GREATEST(0, COALESCE(v_half_day, 100));
    v_full_day := GREATEST(0, COALESCE(v_full_day, 150));
    v_experienced := GREATEST(0, COALESCE(v_experienced, 180));
    v_min_daily := GREATEST(0, COALESCE(v_min_daily, 100));
    v_second := GREATEST(0, COALESCE(v_second, 25));
    v_third := GREATEST(0, COALESCE(v_third, 50));

    IF v_child_count >= 4 AND v_package <> 'negotiable' THEN
      RAISE EXCEPTION 'Four or more children need a custom daily budget.';
    END IF;

    IF v_package = 'half_day' THEN
      v_duration := c_half_hours;
      v_base_daily := v_half_day;
    ELSIF v_package = 'full_day' THEN
      v_duration := c_full_hours;
      v_base_daily := v_full_day;
    ELSIF v_package = 'experienced' THEN
      v_duration := c_full_hours;
      v_base_daily := v_experienced;
    ELSE
      v_duration := c_full_hours;
      IF p_custom_daily_major IS NULL
        OR p_custom_daily_major <> p_custom_daily_major
        OR p_custom_daily_major < v_min_daily THEN
        RAISE EXCEPTION 'Enter a daily budget of at least GH₵%.', v_min_daily;
      END IF;
      v_base_daily := round(p_custom_daily_major::numeric, 2);
    END IF;

    IF v_package = 'negotiable' THEN
      v_child_surcharge := 0;
    ELSIF v_child_count = 2 THEN
      v_child_surcharge := v_second;
    ELSIF v_child_count = 3 THEN
      v_child_surcharge := v_third;
    ELSE
      v_child_surcharge := 0;
    END IF;

    v_extras := 0;
    v_daily := round((v_base_daily + v_child_surcharge)::numeric, 2);
  END IF;

  IF v_frequency IN ('weekly', 'custom') THEN
    v_days := GREATEST(
      1,
      LEAST(
        7,
        COALESCE(
          NULLIF(p_selected_day_count, 0),
          CASE WHEN v_frequency = 'weekly' THEN 7 ELSE 1 END
        )
      )
    );
    v_discount_bps := CASE WHEN v_days = 7 THEN v_weekly_bps ELSE 0 END;
  ELSIF v_frequency = 'monthly' THEN
    IF v_package = 'negotiable' THEN
      RAISE EXCEPTION 'Monthly family care uses a listed package.';
    END IF;

    v_month_end := (date_trunc('month', p_scheduled_date) + INTERVAL '1 month - 1 day')::date;

    SELECT count(*)::integer INTO v_weekday_visits
    FROM generate_series(p_scheduled_date, v_month_end, INTERVAL '1 day') AS visit_day
    WHERE EXTRACT(ISODOW FROM visit_day)::integer BETWEEN 1 AND 5;

    SELECT count(*)::integer INTO v_weekend_visits
    FROM generate_series(p_scheduled_date, v_month_end, INTERVAL '1 day') AS visit_day
    WHERE EXTRACT(ISODOW FROM visit_day)::integer IN (6, 7)
      AND (
        CASE EXTRACT(ISODOW FROM visit_day)::integer
          WHEN 6 THEN 'sat'
          ELSE 'sun'
        END
      ) = ANY (COALESCE(p_weekdays, ARRAY[]::text[]));

    SELECT bs.value_numeric INTO v_monthly_fee
    FROM public.booking_settings bs
    WHERE bs.key = CASE
      WHEN v_is_senior AND v_package = 'half_day' THEN 'family_care_senior_half_day_monthly_major'
      WHEN v_is_senior THEN 'family_care_senior_full_day_monthly_major'
      WHEN v_package = 'half_day' THEN 'family_care_child_half_day_monthly_major'
      WHEN v_package = 'experienced' THEN 'family_care_child_experienced_monthly_major'
      ELSE 'family_care_child_full_day_monthly_major'
    END;

    v_monthly_fee := COALESCE(
      v_monthly_fee,
      CASE
        WHEN v_is_senior AND v_package = 'half_day' THEN 2000
        WHEN v_is_senior THEN 3000
        WHEN v_package = 'half_day' THEN 1700
        WHEN v_package = 'experienced' THEN 3000
        ELSE 2500
      END
    );

    v_days := COALESCE(v_weekday_visits, 0) + COALESCE(v_weekend_visits, 0);
    v_discount_bps := 0;
    v_discount_major := 0;
    v_subtotal_major := round(v_monthly_fee, 2);
    v_weekend_major := round((COALESCE(v_weekend_visits, 0) * v_daily)::numeric, 2);
    v_payable_major := round((v_subtotal_major + v_weekend_major)::numeric, 2);
  ELSE
    v_days := 1;
    v_discount_bps := 0;
  END IF;

  IF v_frequency IS DISTINCT FROM 'monthly' THEN
    v_subtotal_major := round((v_daily * v_days)::numeric, 2);
    v_discount_major := round((v_subtotal_major * v_discount_bps / 10000.0)::numeric, 2);
    v_payable_major := round((v_subtotal_major - v_discount_major)::numeric, 2);
    v_weekend_major := 0;
  END IF;
  IF v_payable_major < 0 THEN
    v_payable_major := 0;
  END IF;
  v_payable_minor := round(v_payable_major * 100)::integer;
  v_weekend_minor := round(COALESCE(v_weekend_major, 0) * 100)::integer;

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
    -- Cast before multiply. Both operands are integers, so a large monthly
    -- total overflows int4 before the division can promote the product.
    v_platform_fee_major := (round(v_payable_minor::numeric * v_platform_bps / 10000.0) / 100.0)::numeric;
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
    'family_care_v1'::text,
    'GHS'::text,
    v_package,
    v_child_count,
    v_duration,
    CASE WHEN v_duration > 0 THEN round((v_daily / v_duration)::numeric, 2) ELSE 0 END,
    v_base_daily,
    v_child_surcharge,
    v_extras,
    v_daily,
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
    v_weekend_minor,
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

COMMENT ON FUNCTION public.compute_family_care_pricing(
  integer, text, integer, date, text, numeric, integer, boolean, boolean, boolean, text[]
) IS
  'Authoritative Family Care pricing. Monthly plans charge a fixed package for Monday–Friday and add optional weekend days at the daily rate. Weekly, custom, and single-day plans keep the daily rate. Platform fee is an earnings split, not an add-on.';

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.compute_family_care_pricing(integer, text, integer, date, text, numeric, integer, boolean, boolean, boolean, text[]) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.compute_family_care_pricing(integer, text, integer, date, text, numeric, integer, boolean, boolean, boolean, text[]) TO authenticated';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping family care pricing grants: %', SQLERRM;
END $$;

COMMIT;
