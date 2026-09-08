-- Canonical worker schedule reservations for Direct and bookings.
--
-- Every future booking write and urgent-help assignment reserves the same
-- worker/time resource. The GiST exclusion constraint is the final atomic guard
-- against cross-workflow double booking. Replacement requests reserve through
-- their canonical booking after that booking is reassigned.

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE public.direct_service_requests
  ADD COLUMN IF NOT EXISTS previous_worker_user_id uuid
    REFERENCES public.users(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.worker_schedule_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  source_kind text NOT NULL CHECK (source_kind IN ('booking', 'direct_request')),
  source_id uuid NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  reservation_period tstzrange NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT worker_schedule_reservations_positive_window CHECK (ends_at > starts_at),
  CONSTRAINT worker_schedule_reservations_source_uniq UNIQUE (source_kind, source_id)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'worker_schedule_reservations_no_overlap'
      AND conrelid = 'public.worker_schedule_reservations'::regclass
  ) THEN
    ALTER TABLE public.worker_schedule_reservations
      ADD CONSTRAINT worker_schedule_reservations_no_overlap
      EXCLUDE USING gist (
        worker_user_id WITH =,
        reservation_period WITH &&
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS worker_schedule_reservations_worker_idx
  ON public.worker_schedule_reservations (worker_user_id, starts_at);

CREATE OR REPLACE FUNCTION public.direct_worker_reservation_buffer_minutes()
RETURNS integer
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_buffer integer := 45;
BEGIN
  IF to_regprocedure('public.resolve_cleaner_job_buffer_minutes()') IS NOT NULL THEN
    EXECUTE 'SELECT public.resolve_cleaner_job_buffer_minutes()' INTO v_buffer;
  END IF;

  RETURN GREATEST(COALESCE(v_buffer, 45), 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_worker_schedule_reservation(
  p_source_kind text,
  p_source_id uuid,
  p_worker_user_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_buffer integer := public.direct_worker_reservation_buffer_minutes();
BEGIN
  IF p_worker_user_id IS NULL
     OR p_starts_at IS NULL
     OR p_ends_at IS NULL
     OR p_ends_at <= p_starts_at THEN
    DELETE FROM public.worker_schedule_reservations
    WHERE source_kind = p_source_kind
      AND source_id = p_source_id;
    RETURN;
  END IF;

  INSERT INTO public.worker_schedule_reservations (
    worker_user_id,
    source_kind,
    source_id,
    starts_at,
    ends_at,
    reservation_period,
    updated_at
  ) VALUES (
    p_worker_user_id,
    p_source_kind,
    p_source_id,
    p_starts_at,
    p_ends_at,
    tstzrange(
      p_starts_at,
      p_ends_at + make_interval(mins => v_buffer),
      '[)'
    ),
    now()
  )
  ON CONFLICT (source_kind, source_id)
  DO UPDATE SET
    worker_user_id = EXCLUDED.worker_user_id,
    starts_at = EXCLUDED.starts_at,
    ends_at = EXCLUDED.ends_at,
    reservation_period = EXCLUDED.reservation_period,
    updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_booking_worker_schedule_reservation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.worker_schedule_reservations
    WHERE source_kind = 'booking'
      AND source_id = OLD.id;
    RETURN OLD;
  END IF;

  IF NEW.cleaner_id IS NULL
     OR NEW.booking_period IS NULL
     OR lower(COALESCE(NEW.status::text, '')) IN ('cancelled', 'completed') THEN
    DELETE FROM public.worker_schedule_reservations
    WHERE source_kind = 'booking'
      AND source_id = NEW.id;
    RETURN NEW;
  END IF;

  PERFORM public.upsert_worker_schedule_reservation(
    'booking',
    NEW.id,
    NEW.cleaner_id,
    lower(NEW.booking_period),
    upper(NEW.booking_period)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_booking_worker_schedule_reservation
  ON public.bookings;
CREATE TRIGGER sync_booking_worker_schedule_reservation
AFTER INSERT OR UPDATE OF cleaner_id, booking_period, status OR DELETE
ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.sync_booking_worker_schedule_reservation();

CREATE OR REPLACE FUNCTION public.sync_direct_request_worker_schedule_reservation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_end timestamptz;
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.worker_schedule_reservations
    WHERE source_kind = 'direct_request'
      AND source_id = OLD.id;
    RETURN OLD;
  END IF;

  -- Replacements reserve through the canonical booking after reassignment.
  -- Resolved urgent work remains reserved for its scheduled window so an
  -- operator cannot accidentally free future capacity by closing the ticket.
  IF NEW.kind <> 'urgent_help'
     OR NEW.status NOT IN ('assigned', 'resolved')
     OR NEW.assigned_worker_user_id IS NULL
     OR NEW.requested_start_at IS NULL
     OR NEW.duration_hours IS NULL THEN
    DELETE FROM public.worker_schedule_reservations
    WHERE source_kind = 'direct_request'
      AND source_id = NEW.id;
    RETURN NEW;
  END IF;

  v_end := NEW.requested_start_at
    + make_interval(secs => (NEW.duration_hours * 3600)::double precision);

  PERFORM public.upsert_worker_schedule_reservation(
    'direct_request',
    NEW.id,
    NEW.assigned_worker_user_id,
    NEW.requested_start_at,
    v_end
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_direct_request_worker_schedule_reservation
  ON public.direct_service_requests;
CREATE TRIGGER sync_direct_request_worker_schedule_reservation
AFTER INSERT OR UPDATE OF status, assigned_worker_user_id, requested_start_at, duration_hours OR DELETE
ON public.direct_service_requests
FOR EACH ROW EXECUTE FUNCTION public.sync_direct_request_worker_schedule_reservation();

-- Backfill only Direct reservations. Existing bookings remain covered by the
-- legacy bookings conflict query and will gain reservation rows on their next
-- scheduling/assignment write. This avoids making deployment depend on legacy
-- buffer-only overlaps that predate Direct.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id, assigned_worker_user_id, requested_start_at,
           requested_start_at
             + make_interval(secs => (duration_hours * 3600)::double precision) AS ends_at
    FROM public.direct_service_requests
    WHERE kind = 'urgent_help'
      AND status IN ('assigned', 'resolved')
      AND assigned_worker_user_id IS NOT NULL
      AND requested_start_at IS NOT NULL
      AND duration_hours IS NOT NULL
  LOOP
    PERFORM public.upsert_worker_schedule_reservation(
      'direct_request', r.id, r.assigned_worker_user_id, r.requested_start_at, r.ends_at
    );
  END LOOP;
END $$;

-- Extend the shared conflict helper so discovery/search paths also see Direct
-- reservations instead of learning about them only when a write is attempted.
CREATE OR REPLACE FUNCTION public.cleaner_has_booking_conflict(
  p_cleaner_id uuid,
  p_booking_start timestamptz,
  p_booking_end timestamptz,
  p_exclude_booking_id uuid DEFAULT NULL,
  p_buffer_minutes integer DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.cleaner_id = p_cleaner_id
        AND b.status NOT IN ('cancelled', 'completed')
        AND (
          p_exclude_booking_id IS NULL
          OR b.id <> p_exclude_booking_id
        )
        AND b.booking_period IS NOT NULL
        AND tstzrange(
          lower(b.booking_period)
            - make_interval(
              mins => GREATEST(
                COALESCE(p_buffer_minutes, public.resolve_cleaner_job_buffer_minutes()),
                0
              )
            ),
          upper(b.booking_period)
            + make_interval(
              mins => GREATEST(
                COALESCE(p_buffer_minutes, public.resolve_cleaner_job_buffer_minutes()),
                0
              )
            ),
          '[)'
        ) && tstzrange(p_booking_start, p_booking_end, '[)')
    )
    OR EXISTS (
      SELECT 1
      FROM public.worker_schedule_reservations r
      WHERE r.worker_user_id = p_cleaner_id
        AND NOT (
          r.source_kind = 'booking'
          AND p_exclude_booking_id IS NOT NULL
          AND r.source_id = p_exclude_booking_id
        )
        AND r.reservation_period && tstzrange(
          p_booking_start,
          p_booking_end
            + make_interval(
              mins => GREATEST(
                COALESCE(p_buffer_minutes, public.direct_worker_reservation_buffer_minutes()),
                0
              )
            ),
          '[)'
        )
    );
$$;

COMMENT ON TABLE public.worker_schedule_reservations IS
  'Atomic worker/time reservations shared by booking writes and Direct urgent-help assignments.';
