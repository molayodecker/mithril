-- Serialize every booking/direct reservation mutation for a worker on the same
-- transaction-scoped advisory lock used by Direct dispatch assignment. This
-- closes the cross-workflow race where a regular booking could be inserted
-- between Direct's availability pre-check and its final assignment write.

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

  PERFORM pg_advisory_xact_lock(hashtextextended(p_worker_user_id::text, 0));

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

COMMENT ON FUNCTION public.upsert_worker_schedule_reservation IS
  'Atomically serializes and writes canonical worker schedule reservations.';
