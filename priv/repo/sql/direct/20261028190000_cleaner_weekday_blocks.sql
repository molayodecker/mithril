-- Recurring weekdays a worker does not work. An empty set means no weekday
-- restriction. Date-specific time off stays in cleaner_availability_exceptions.

CREATE TABLE IF NOT EXISTS public.cleaner_weekday_blocks (
  cleaner_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cleaner_id, day_of_week)
);

COMMENT ON TABLE public.cleaner_weekday_blocks IS
  'Weekdays (0=Sunday through 6=Saturday) the worker has turned off. New bookings on those weekdays are refused. No rows means the worker has not set weekday blocks.';

CREATE OR REPLACE FUNCTION public.replace_cleaner_weekday_blocks(p_days integer[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF p_days IS NULL
     OR EXISTS (
       SELECT 1
       FROM unnest(p_days) AS day_value
       WHERE day_value IS NULL OR day_value < 0 OR day_value > 6
     ) THEN
    RAISE EXCEPTION 'invalid weekday' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.cleaner_weekday_blocks
  WHERE cleaner_id = caller;

  INSERT INTO public.cleaner_weekday_blocks (cleaner_id, day_of_week)
  SELECT DISTINCT caller, day_value
  FROM unnest(p_days) AS day_value;
END;
$$;

COMMENT ON FUNCTION public.replace_cleaner_weekday_blocks(integer[]) IS
  'Replaces the signed-in worker''s blocked weekdays in one transaction. An empty array clears every block.';

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.replace_cleaner_weekday_blocks(integer[]) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.replace_cleaner_weekday_blocks(integer[]) TO authenticated';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping replace_cleaner_weekday_blocks grants: %', SQLERRM;
END $$;
