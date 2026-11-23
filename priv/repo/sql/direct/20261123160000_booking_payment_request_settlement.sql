-- Mithril settles a booking payment link as schema_admin, with no client JWT.
-- Production's payment-status guard still blocked every non-service_role write,
-- so a paid link could not mark the booking paid.

CREATE OR REPLACE FUNCTION public.guard_booking_payment_status_writes()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF coalesce(nullif(current_setting('app.confirm_zero_amount', true), ''), '') = '1' THEN
    RETURN NEW;
  END IF;

  IF coalesce(nullif(current_setting('app.settle_admin_monthly_schedule', true), ''), '') = '1' THEN
    RETURN NEW;
  END IF;

  -- Fly/Mithril and other server sessions have no client JWT role.
  IF auth.role() IS DISTINCT FROM 'authenticated'
     AND auth.role() IS DISTINCT FROM 'anon' THEN
    RETURN NEW;
  END IF;

  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status
     AND NEW.payment_status IN ('paid', 'refunded') THEN
    RAISE EXCEPTION
      'payment_status transitions to % are server-only (use the Paystack webhook)',
      NEW.payment_status
      USING ERRCODE = '42501';
  END IF;

  IF OLD.payment_status = 'paid'
     AND NEW.payment_status IS DISTINCT FROM OLD.payment_status THEN
    RAISE EXCEPTION
      'cannot change payment_status of a paid booking from client'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- A paid booking payment link is a booking payment. The hourly stale-pending
-- job must not cancel that booking when the request is already paid.

CREATE OR REPLACE FUNCTION public.expire_stale_pending_bookings()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  affected integer;
  v_now timestamptz := now();
BEGIN
  UPDATE public.bookings
  SET
    status = 'cancelled'::booking_status,
    updated_at = v_now
  WHERE status = 'pending'::booking_status
    AND payment_status = 'pending'
    AND subscription_id IS NULL
    AND created_at < (v_now - interval '48 hours')
    AND updated_at < (v_now - interval '48 hours')
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_payment_requests request
      WHERE request.booking_id = bookings.id
        AND request.status = 'paid'
    );

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$function$
