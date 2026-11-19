-- Local regression for compute_booking_pricing_with_promotion.
-- Runs inside a transaction and rolls back, so mithril_test is unchanged.
-- The stubbed base function raises on a short visit clock. The function under
-- test must return the labor price instead of failing the whole call.

BEGIN;

CREATE EXTENSION IF NOT EXISTS citext;

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE public.promotions (
  id uuid PRIMARY KEY,
  slug text,
  type text,
  value integer,
  channel text,
  allow_recurring boolean,
  max_duration_hours numeric,
  active boolean
);

CREATE TABLE public.promotion_codes (
  id uuid PRIMARY KEY,
  code citext,
  active boolean,
  promotion_id uuid
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULL::uuid
$$;

CREATE OR REPLACE FUNCTION public.compute_booking_pricing(
  p_service_id integer,
  p_duration_hours_raw numeric,
  p_scheduled_date date,
  p_service_timezone text,
  p_recurrence_interval text,
  p_is_recurring boolean,
  p_include_booking_cover boolean,
  p_supplies_option text,
  p_cleaner_id uuid,
  p_extra_task_ids text[],
  p_service_duration_option_id uuid,
  p_visit_duration_hours numeric,
  p_cleaning_scan_id uuid
)
RETURNS TABLE (
  pricing_version text,
  currency text,
  work_rate_ghs_per_hour numeric,
  duration_hours numeric,
  subtotal_labor_major numeric,
  platform_fee_major numeric,
  booking_cover_major numeric,
  supplies_option text,
  supplies_allowance_minor integer,
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
  cleaner_earnings_minor integer,
  catalog_discount_pct numeric,
  catalog_discount_minor integer
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_visit_duration_hours IS NOT NULL AND p_visit_duration_hours < 2 THEN
    RAISE EXCEPTION 'Minimum duration for this service is 2 hours';
  END IF;

  pricing_version := 'visit';
  currency := 'GHS';
  work_rate_ghs_per_hour := 80;
  duration_hours := 8.5;
  subtotal_labor_major := 680;
  platform_fee_major := 102;
  booking_cover_major := 21;
  supplies_option := COALESCE(p_supplies_option, 'customer_provided');
  supplies_allowance_minor := 0;
  core_amount_minor := 80300;
  same_day_surcharge_bps := 0;
  weekend_surcharge_bps := 0;
  recurring_weekly_discount_bps := 0;
  recurring_monthly_discount_bps := 0;
  same_day_surcharge_minor := 0;
  weekend_surcharge_minor := 0;
  recurring_discount_minor := 0;
  final_amount_minor := 80300;
  recurring_amount_minor := NULL;
  first_charge_amount_minor := NULL;
  discount_rate_bps := NULL;
  is_same_day := false;
  is_weekend := false;
  minimum_duration_hours := 2;
  cleaner_earnings_minor := 68000;
  catalog_discount_pct := NULL;
  catalog_discount_minor := 0;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.compute_booking_pricing(
  p_service_id integer,
  p_duration_hours_raw numeric,
  p_scheduled_date date,
  p_service_timezone text,
  p_recurrence_interval text,
  p_is_recurring boolean,
  p_include_booking_cover boolean,
  p_supplies_option text,
  p_cleaner_id uuid,
  p_extra_task_ids text[],
  p_service_duration_option_id uuid
)
RETURNS TABLE (
  pricing_version text,
  currency text,
  work_rate_ghs_per_hour numeric,
  duration_hours numeric,
  subtotal_labor_major numeric,
  platform_fee_major numeric,
  booking_cover_major numeric,
  supplies_option text,
  supplies_allowance_minor integer,
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
  cleaner_earnings_minor integer,
  catalog_discount_pct numeric,
  catalog_discount_minor integer
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_service_id = 99 THEN
    RAISE EXCEPTION 'labor pricing failed';
  END IF;

  pricing_version := 'labor';
  currency := 'GHS';
  work_rate_ghs_per_hour := 80;
  duration_hours := p_duration_hours_raw;
  subtotal_labor_major := 320;
  platform_fee_major := 48;
  booking_cover_major := 21;
  supplies_option := COALESCE(p_supplies_option, 'customer_provided');
  supplies_allowance_minor := 0;
  core_amount_minor := 38900;
  same_day_surcharge_bps := 0;
  weekend_surcharge_bps := 0;
  recurring_weekly_discount_bps := 0;
  recurring_monthly_discount_bps := 0;
  same_day_surcharge_minor := 0;
  weekend_surcharge_minor := 0;
  recurring_discount_minor := 0;
  final_amount_minor := 38900;
  recurring_amount_minor := NULL;
  first_charge_amount_minor := NULL;
  discount_rate_bps := NULL;
  is_same_day := false;
  is_weekend := false;
  minimum_duration_hours := 2;
  cleaner_earnings_minor := 32000;
  catalog_discount_pct := NULL;
  catalog_discount_minor := 0;
  RETURN NEXT;
END;
$$;

\ir ../../priv/repo/sql/direct/20261119180000_promo_pricing_returns_base_on_offer_error.sql

DO $$
DECLARE
  priced record;
BEGIN
  SELECT *
  INTO priced
  FROM public.compute_booking_pricing_with_promotion(
    p_service_id := 1,
    p_duration_hours_raw := 8.5,
    p_scheduled_date := CURRENT_DATE + 1,
    p_service_timezone := 'Africa/Accra',
    p_visit_duration_hours := 5
  );

  IF priced.pricing_version IS DISTINCT FROM 'visit'
     OR priced.duration_hours IS DISTINCT FROM 8.5
     OR priced.final_amount_minor IS DISTINCT FROM 80300
     OR priced.promotion_slug IS NOT NULL
     OR priced.promotion_discount_minor IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'valid visit should use the visit price, got % % %',
      priced.pricing_version, priced.duration_hours, priced.final_amount_minor;
  END IF;
END $$;

DO $$
DECLARE
  priced record;
BEGIN
  SELECT *
  INTO priced
  FROM public.compute_booking_pricing_with_promotion(
    p_service_id := 1,
    p_duration_hours_raw := 8.5,
    p_scheduled_date := CURRENT_DATE + 1,
    p_service_timezone := 'Africa/Accra',
    p_promotion_slug := 'welcome_risk_free_mobile_v1',
    p_channel := 'mobile',
    p_visit_duration_hours := 1
  );

  IF priced.pricing_version IS DISTINCT FROM 'labor'
     OR priced.duration_hours IS DISTINCT FROM 8.5
     OR priced.final_amount_minor IS DISTINCT FROM 38900
     OR priced.promotion_slug IS NOT NULL THEN
    RAISE EXCEPTION 'short visit should fall back to labor price, got % % % promo %',
      priced.pricing_version, priced.duration_hours, priced.final_amount_minor, priced.promotion_slug;
  END IF;
END $$;

DO $$
DECLARE
  priced record;
BEGIN
  SELECT *
  INTO priced
  FROM public.compute_booking_pricing_with_promotion(
    p_service_id := 1,
    p_duration_hours_raw := 8.5,
    p_scheduled_date := CURRENT_DATE + 1,
    p_service_timezone := 'Africa/Accra',
    p_promotion_slug := 'welcome_risk_free_mobile_v1',
    p_channel := 'not-a-channel',
    p_visit_duration_hours := 5
  );

  IF priced.pricing_version IS DISTINCT FROM 'visit'
     OR priced.final_amount_minor IS DISTINCT FROM 80300
     OR priced.promotion_slug IS NOT NULL
     OR priced.promotion_discount_minor IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'invalid offer channel should keep the visit price, got % %',
      priced.pricing_version, priced.promotion_slug;
  END IF;
END $$;

DO $$
BEGIN
  PERFORM *
  FROM public.compute_booking_pricing_with_promotion(
    p_service_id := 99,
    p_duration_hours_raw := 8.5,
    p_scheduled_date := CURRENT_DATE + 1,
    p_service_timezone := 'Africa/Accra',
    p_visit_duration_hours := 1
  );

  RAISE EXCEPTION 'both pricing attempts should fail';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%labor pricing failed%' THEN
      RAISE EXCEPTION 'unexpected pricing failure: %', SQLERRM;
    END IF;
END $$;

ROLLBACK;
