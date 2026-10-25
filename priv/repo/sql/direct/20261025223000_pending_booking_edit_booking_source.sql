-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
--
-- Pending-edit hydration must return bookings.booking_source on the same read.
-- CREATE OR REPLACE cannot change RETURNS TABLE, so replace the function.
-- This file is replayed on deploy. Fly MPG rejects GRANT/REVOKE on system roles;
-- that error is ignored so a later replay does not stop the schema apply.

DROP FUNCTION IF EXISTS public.get_pending_booking_for_edit(uuid, uuid);

CREATE FUNCTION public.get_pending_booking_for_edit(
  p_customer_id uuid,
  p_booking_id uuid
)
RETURNS TABLE (
  id uuid,
  customer_id uuid,
  cleaner_id uuid,
  direct_assigned_cleaner_id uuid,
  service_id integer,
  title text,
  scheduled_date date,
  scheduled_time time without time zone,
  duration_hours numeric,
  address text,
  special_instructions text,
  status public.booking_status,
  payment_status text,
  subscription_id uuid,
  home_size text,
  extra_task_ids text[],
  duration_adjustment numeric,
  duration_computed numeric,
  duration_final numeric,
  timezone_name text,
  cleaner_assigned_at timestamptz,
  service_duration_option_id uuid,
  location_latitude double precision,
  location_longitude double precision,
  customer_contact_phone text,
  booking_source text,
  booking_cover boolean,
  booking_cover_amount numeric,
  platform_fee numeric,
  work_rate_ghs_per_hour numeric,
  pricing_version text,
  currency text,
  promotion_id uuid,
  promotion_slug text,
  promotion_discount_minor integer,
  final_amount_minor integer,
  supplies_option text,
  supplies_allowance_minor integer,
  transportation_included boolean,
  transportation_minor integer,
  transportation_quote_id uuid,
  service jsonb
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT
    b.id,
    b.customer_id,
    b.cleaner_id,
    b.direct_assigned_cleaner_id,
    b.service_id,
    b.title,
    b.scheduled_date,
    b.scheduled_time,
    b.duration_hours,
    b.address,
    b.special_instructions,
    b.status,
    b.payment_status,
    b.subscription_id,
    b.home_size,
    b.extra_task_ids,
    b.duration_adjustment,
    b.duration_computed,
    b.duration_final,
    b.timezone_name,
    b.cleaner_assigned_at,
    b.service_duration_option_id,
    CASE
      WHEN b.location_coordinates IS NOT NULL
        THEN ST_Y(b.location_coordinates::geometry)
      ELSE NULL
    END AS location_latitude,
    CASE
      WHEN b.location_coordinates IS NOT NULL
        THEN ST_X(b.location_coordinates::geometry)
      ELSE NULL
    END AS location_longitude,
    b.customer_contact_phone,
    b.booking_source,
    COALESCE(b.booking_cover, true) AS booking_cover,
    b.booking_cover_amount,
    b.platform_fee,
    b.work_rate_ghs_per_hour,
    b.pricing_version,
    b.currency,
    b.promotion_id,
    b.promotion_slug,
    COALESCE(b.promotion_discount_minor, 0) AS promotion_discount_minor,
    COALESCE(NULLIF(b.final_amount_minor, 0), NULLIF(b.total_price, 0), 0) AS final_amount_minor,
    b.supplies_option,
    COALESCE(b.supplies_allowance_minor, 0) AS supplies_allowance_minor,
    COALESCE(b.transportation_included, false) AS transportation_included,
    COALESCE(b.transportation_minor, 0) AS transportation_minor,
    b.transportation_quote_id,
    to_jsonb(s.*) AS service
  FROM public.bookings b
  JOIN public.service_types s
    ON s.id = b.service_id
  WHERE b.id = p_booking_id
    AND b.customer_id = auth.uid()
    AND b.customer_id = p_customer_id
    AND b.status IN ('pending', 'confirmed', 'scheduled')
    AND b.subscription_id IS NULL
  LIMIT 1;
$$;

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.get_pending_booking_for_edit(uuid, uuid) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_pending_booking_for_edit(uuid, uuid) TO authenticated';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping get_pending_booking_for_edit grants: %', SQLERRM;
END $$;
