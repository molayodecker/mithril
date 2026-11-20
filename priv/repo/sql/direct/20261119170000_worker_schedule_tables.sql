-- Weekly hours and date-specific time off. Production already has these
-- tables from the legacy schema. A local database built only from later
-- Direct SQL does not, and the worker Schedule screen then returns 400.
-- CREATE TABLE IF NOT EXISTS leaves an existing production table unchanged.

CREATE TABLE IF NOT EXISTS public.availability (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cleaner_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
  start_time timestamptz NOT NULL,
  end_time timestamptz NOT NULL,
  is_recurring boolean DEFAULT false,
  day_of_week integer,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.cleaner_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cleaner_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
  day_of_week text NOT NULL,
  start_time time without time zone NOT NULL,
  end_time time without time zone NOT NULL,
  CONSTRAINT cleaner_schedules_day_of_week_check CHECK (
    day_of_week = ANY (
      ARRAY['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_cleaner_schedules_cleaner_id
  ON public.cleaner_schedules (cleaner_id);

CREATE TABLE IF NOT EXISTS public.cleaner_availability_exceptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cleaner_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  exception_date date NOT NULL,
  reason text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT cleaner_availability_exceptions_cleaner_id_exception_date_key
    UNIQUE (cleaner_id, exception_date)
);

CREATE INDEX IF NOT EXISTS idx_cleaner_availability_exceptions_cleaner_id
  ON public.cleaner_availability_exceptions (cleaner_id);

CREATE INDEX IF NOT EXISTS idx_cleaner_availability_exceptions_date
  ON public.cleaner_availability_exceptions (exception_date);

CREATE INDEX IF NOT EXISTS idx_cleaner_availability_exceptions_cleaner_date
  ON public.cleaner_availability_exceptions (cleaner_id, exception_date);
