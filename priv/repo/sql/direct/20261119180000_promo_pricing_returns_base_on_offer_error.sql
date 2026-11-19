-- A promotion lookup must not hide the base price.
-- Visit-clock pricing can raise (for example a visit shorter than the service
-- minimum) even when labor hours are valid. Retry without the visit clock.
-- Any later offer failure returns that base price instead of database_error.

DROP FUNCTION IF EXISTS public.compute_booking_pricing_with_promotion(
  integer, numeric, date, text, uuid, text, text, boolean, boolean, text, uuid, text, double precision, double precision, text[], uuid, uuid, text
);

CREATE OR REPLACE FUNCTION public.compute_booking_pricing_with_promotion(
  p_service_id integer,
  p_duration_hours_raw numeric,
  p_scheduled_date date,
  p_service_timezone text,
  p_cleaner_id uuid DEFAULT NULL,
  p_channel text DEFAULT NULL,
  p_recurrence_interval text DEFAULT NULL,
  p_is_recurring boolean DEFAULT false,
  p_include_booking_cover boolean DEFAULT true,
  p_supplies_option text DEFAULT 'customer_provided',
  p_customer_id uuid DEFAULT NULL,
  p_promotion_slug text DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_extra_task_ids text[] DEFAULT NULL,
  p_booking_id uuid DEFAULT NULL,
  p_service_duration_option_id uuid DEFAULT NULL,
  p_promotion_code text DEFAULT NULL,
  p_visit_duration_hours numeric DEFAULT NULL,
  p_cleaning_scan_id uuid DEFAULT NULL
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
  catalog_discount_minor integer,
  promotion_id uuid,
  promotion_slug text,
  promotion_discount_minor integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_base record;
  v_promo public.promotions;
  v_eligibility jsonb;
  v_referral jsonb;
  v_extra_hours numeric;
  v_base_promo_hours numeric;
  v_free_hours numeric;
  v_promo_labor_minor integer;
  v_labor_minor integer;
  v_discount integer := 0;
  v_final integer;
  v_first_charge integer;
  v_cleaner_earnings_minor integer;
  v_caller uuid := auth.uid();
  v_resolved_slug text;
  v_code_row public.promotion_codes%ROWTYPE;
  v_use_code boolean := false;
BEGIN
  BEGIN
    SELECT *
    INTO v_base
    FROM public.compute_booking_pricing(
      p_service_id,
      p_duration_hours_raw,
      p_scheduled_date,
      p_service_timezone,
      p_recurrence_interval,
      p_is_recurring,
      p_include_booking_cover,
      p_supplies_option,
      p_cleaner_id,
      p_extra_task_ids,
      p_service_duration_option_id,
      p_visit_duration_hours,
      p_cleaning_scan_id
    )
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Pricing returned no row';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'compute_booking_pricing_with_promotion visit pricing failed: %', SQLERRM;
      SELECT *
      INTO v_base
      FROM public.compute_booking_pricing(
        p_service_id,
        p_duration_hours_raw,
        p_scheduled_date,
        p_service_timezone,
        p_recurrence_interval,
        p_is_recurring,
        p_include_booking_cover,
        p_supplies_option,
        p_cleaner_id,
        p_extra_task_ids,
        p_service_duration_option_id
      )
      LIMIT 1;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Pricing returned no row';
      END IF;
  END;

  BEGIN
  v_labor_minor := round(greatest(0, v_base.subtotal_labor_major) * 100)::integer;
  v_resolved_slug := NULLIF(btrim(p_promotion_slug), '');

  IF p_promotion_code IS NOT NULL AND btrim(p_promotion_code) <> '' THEN
    SELECT pc.*
    INTO v_code_row
    FROM public.promotion_codes pc
    WHERE pc.code = btrim(p_promotion_code)::citext
      AND pc.active IS TRUE
    LIMIT 1;

    IF v_code_row.id IS NULL THEN
      RETURN QUERY
      SELECT
        v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
        v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
        v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
        v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
        v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
        v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
        v_base.final_amount_minor, v_base.recurring_amount_minor,
        v_base.first_charge_amount_minor, v_base.discount_rate_bps,
        v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
        v_base.cleaner_earnings_minor,
        v_base.catalog_discount_pct, v_base.catalog_discount_minor,
        NULL::uuid, NULL::text, 0;
      RETURN;
    END IF;

    SELECT p.slug INTO v_resolved_slug FROM public.promotions p WHERE p.id = v_code_row.promotion_id;
    v_use_code := true;
  END IF;

  IF v_resolved_slug IS NULL THEN
    RETURN QUERY
    SELECT
      v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
      v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
      v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
      v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
      v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
      v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
      v_base.final_amount_minor, v_base.recurring_amount_minor,
      v_base.first_charge_amount_minor, v_base.discount_rate_bps,
      v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
      v_base.cleaner_earnings_minor,
      v_base.catalog_discount_pct, v_base.catalog_discount_minor,
      NULL::uuid, NULL::text, 0;
    RETURN;
  END IF;

  IF p_channel IS NULL
     OR btrim(p_channel) = ''
     OR p_channel NOT IN ('mobile', 'web') THEN
    RAISE EXCEPTION 'Invalid promotion channel: %', p_channel;
  END IF;

  IF p_customer_id IS NULL
     OR v_caller IS NULL
     OR v_caller <> p_customer_id
     OR (NOT COALESCE((SELECT allow_recurring FROM public.promotions WHERE slug = v_resolved_slug LIMIT 1), false)
         AND p_is_recurring) THEN
    RETURN QUERY
    SELECT
      v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
      v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
      v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
      v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
      v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
      v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
      v_base.final_amount_minor, v_base.recurring_amount_minor,
      v_base.first_charge_amount_minor, v_base.discount_rate_bps,
      v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
      v_base.cleaner_earnings_minor,
      v_base.catalog_discount_pct, v_base.catalog_discount_minor,
      NULL::uuid, NULL::text, 0;
    RETURN;
  END IF;

  IF v_use_code THEN
    v_eligibility := public._promotion_eligibility_core(
      p_customer_id,
      v_resolved_slug,
      p_channel,
      p_service_id,
      p_lat,
      p_lng,
      p_extra_task_ids,
      p_is_recurring,
      p_booking_id,
      v_code_row.id
    );
  ELSE
    v_referral := public.get_referral_offer_eligibility(
      p_customer_id,
      p_channel,
      p_service_id,
      p_lat,
      p_lng,
      p_extra_task_ids,
      p_is_recurring,
      p_booking_id
    );

    IF COALESCE((v_referral ->> 'eligible')::boolean, false) IS TRUE THEN
      v_eligibility := v_referral;
      v_resolved_slug := v_referral ->> 'promotion_slug';
    ELSIF NOT public._is_referral_promotion_slug(v_resolved_slug) THEN
      v_eligibility := public.get_welcome_offer_eligibility(
        p_customer_id,
        v_resolved_slug,
        p_channel,
        p_service_id,
        p_lat,
        p_lng,
        p_extra_task_ids,
        p_is_recurring,
        p_booking_id
      );
    ELSE
      v_eligibility := jsonb_build_object('eligible', false, 'reason', 'not_referred');
    END IF;
  END IF;

  IF COALESCE((v_eligibility ->> 'eligible')::boolean, false) IS NOT TRUE THEN
    RETURN QUERY
    SELECT
      v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
      v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
      v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
      v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
      v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
      v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
      v_base.final_amount_minor, v_base.recurring_amount_minor,
      v_base.first_charge_amount_minor, v_base.discount_rate_bps,
      v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
      v_base.cleaner_earnings_minor,
      v_base.catalog_discount_pct, v_base.catalog_discount_minor,
      NULL::uuid, NULL::text, 0;
    RETURN;
  END IF;

  SELECT * INTO v_promo FROM public._load_active_promotion(v_resolved_slug);

  IF v_promo.id IS NULL
     OR v_promo.channel NOT IN (p_channel, 'all') THEN
    RETURN QUERY
    SELECT
      v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
      v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
      v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
      v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
      v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
      v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
      v_base.final_amount_minor, v_base.recurring_amount_minor,
      v_base.first_charge_amount_minor, v_base.discount_rate_bps,
      v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
      v_base.cleaner_earnings_minor,
      v_base.catalog_discount_pct, v_base.catalog_discount_minor,
      NULL::uuid, NULL::text, 0;
    RETURN;
  END IF;

  IF v_promo.type = 'free_hours' THEN
    v_extra_hours := public._extra_task_hours_total(p_extra_task_ids);
    v_base_promo_hours := greatest(0, v_base.duration_hours - v_extra_hours);

    v_free_hours := least(
      v_promo.value::numeric,
      COALESCE(v_promo.max_duration_hours, v_promo.value::numeric),
      v_base_promo_hours
    );

    v_promo_labor_minor := round(
      greatest(0, v_free_hours * v_base.work_rate_ghs_per_hour * 100)
    )::integer;

    v_discount := least(v_promo_labor_minor, v_labor_minor);
  ELSIF v_promo.type = 'percent_off' THEN
    IF v_promo.value IS NULL OR v_promo.value <= 0 OR v_promo.value > 100 THEN
      v_discount := 0;
    ELSE
      v_discount := least(
        round(v_base.final_amount_minor * v_promo.value / 100.0)::integer,
        v_base.final_amount_minor
      );
    END IF;
  ELSIF v_promo.type = 'fixed_credit_minor' THEN
    v_discount := least(
      greatest(0, round(v_promo.value)::integer),
      v_base.final_amount_minor
    );
  ELSE
    v_discount := 0;
  END IF;

  v_final := greatest(0, v_base.final_amount_minor - v_discount);
  v_first_charge := greatest(
    0,
    coalesce(v_base.first_charge_amount_minor, v_base.final_amount_minor) - v_discount
  );
  v_cleaner_earnings_minor := v_base.cleaner_earnings_minor;

  RETURN QUERY
  SELECT
    v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
    v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
    v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
    v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
    v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
    v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
    v_final, v_base.recurring_amount_minor, v_first_charge,
    v_base.discount_rate_bps, v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
    v_cleaner_earnings_minor,
    v_base.catalog_discount_pct, v_base.catalog_discount_minor,
    v_promo.id, v_promo.slug, v_discount;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'compute_booking_pricing_with_promotion offer failed: %', SQLERRM;
      RETURN QUERY
      SELECT
        v_base.pricing_version, v_base.currency, v_base.work_rate_ghs_per_hour,
        v_base.duration_hours, v_base.subtotal_labor_major, v_base.platform_fee_major,
        v_base.booking_cover_major, v_base.supplies_option, v_base.supplies_allowance_minor, v_base.core_amount_minor, v_base.same_day_surcharge_bps,
        v_base.weekend_surcharge_bps, v_base.recurring_weekly_discount_bps,
        v_base.recurring_monthly_discount_bps, v_base.same_day_surcharge_minor,
        v_base.weekend_surcharge_minor, v_base.recurring_discount_minor,
        v_base.final_amount_minor, v_base.recurring_amount_minor,
        v_base.first_charge_amount_minor, v_base.discount_rate_bps,
        v_base.is_same_day, v_base.is_weekend, v_base.minimum_duration_hours,
        v_base.cleaner_earnings_minor,
        v_base.catalog_discount_pct, v_base.catalog_discount_minor,
        NULL::uuid, NULL::text, 0;
  END;
END;
$$;


DO $$
BEGIN
  EXECUTE $grant$
    REVOKE ALL ON FUNCTION public.compute_booking_pricing_with_promotion(
      integer, numeric, date, text, uuid, text, text, boolean, boolean, text, uuid, text, double precision, double precision, text[], uuid, uuid, text, numeric, uuid
    ) FROM PUBLIC, anon
  $grant$;
  EXECUTE $grant$
    GRANT EXECUTE ON FUNCTION public.compute_booking_pricing_with_promotion(
      integer, numeric, date, text, uuid, text, text, boolean, boolean, text, uuid, text, double precision, double precision, text[], uuid, uuid, text, numeric, uuid
    ) TO authenticated, service_role
  $grant$;
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping promo pricing grants: %', SQLERRM;
END $$;

COMMENT ON FUNCTION public.compute_booking_pricing_with_promotion(
  integer, numeric, date, text, uuid, text, text, boolean, boolean, text, uuid, text, double precision, double precision, text[], uuid, uuid, text, numeric, uuid
) IS
  'Authoritative promo pricing: referral 25% (when eligible), welcome slugs, voucher codes (p_promotion_code), and package tiers. Optional Smart Scan id derives labor from cleaning_scans.analysis.';
