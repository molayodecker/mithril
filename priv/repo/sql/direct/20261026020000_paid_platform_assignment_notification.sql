-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
--
-- A paid assignment stays an offer until the worker accepts it.
-- This function must not set cleaner_accepted_at or assignment_phase = 'accepted'.

CREATE OR REPLACE FUNCTION public.trg_init_direct_assignment_on_paid()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_hold_minutes integer;
  v_trust_booking_id uuid;
BEGIN
  IF lower(COALESCE(NEW.payment_status, '')) <> 'paid' THEN
    RETURN NEW;
  END IF;

  -- Row is not visible during BEFORE INSERT; avoid booking-not-found raise.
  v_trust_booking_id := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE NEW.id END;

  IF NEW.customer_id IS NOT NULL
     AND NOT public.customer_trust_can_dispatch_cleaner(NEW.customer_id, v_trust_booking_id) THEN
    IF NEW.cleaner_id IS NOT NULL THEN
      IF NEW.direct_assigned_cleaner_id IS NULL THEN
        NEW.direct_assigned_cleaner_id := NEW.cleaner_id;
      END IF;
      NEW.cleaner_id := NULL;
    END IF;
    IF NEW.dispatch_gated_at IS NULL THEN
      NEW.dispatch_gated_at := now();
    END IF;
    IF NEW.dispatch_gate_reason IS NULL THEN
      NEW.dispatch_gate_reason := 'customer_verification_required';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND lower(COALESCE(OLD.payment_status, '')) = 'paid'
  THEN
    RETURN NEW;
  END IF;

  -- Chosen-worker and platform assignments both wait for the worker to accept.
  IF NEW.cleaner_id IS NOT NULL
     AND NEW.cleaner_accepted_at IS NULL
     AND (NEW.assignment_phase IS NULL OR NEW.assignment_phase = 'exclusive')
     AND (
       NEW.direct_assigned_cleaner_id IS NULL
       OR NEW.direct_assigned_cleaner_id = NEW.cleaner_id
     )
  THEN
    v_hold_minutes := public.direct_assignment_hold_minutes(NEW.scheduled_date, NEW.timezone_name);
    NEW.assignment_phase := 'exclusive';
    NEW.assignment_hold_until := now() + (v_hold_minutes || ' minutes')::interval;
    NEW.assignment_reminder_sent_at := NULL;
    IF NEW.status = 'pending' THEN
      NEW.status := 'confirmed';
    END IF;

    INSERT INTO public.notifications (user_id, type, title, message, data)
    VALUES (
      NEW.cleaner_id,
      'direct_assignment_offer',
      'You were selected for a job',
      format(
        'You''ve been selected for a job. Accept within %s minutes before it is offered to other cleaners.',
        v_hold_minutes
      ),
      jsonb_build_object(
        'booking_id', NEW.id,
        'bookingId', NEW.id,
        'type', 'direct_assignment_offer',
        'audience', 'worker',
        'assignment_phase', 'exclusive',
        'hold_minutes', v_hold_minutes
      )
    );
  END IF;

  RETURN NEW;
END;
$function$;
