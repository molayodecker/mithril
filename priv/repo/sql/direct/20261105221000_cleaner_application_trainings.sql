-- Training answers collected with a cleaner application (CPR, cook).
-- The mobile app upserts one row per application and kind.

CREATE TABLE IF NOT EXISTS public.cleaner_application_trainings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES public.cleaner_applications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('cpr', 'cook')),
  has_training boolean NOT NULL,
  provider text,
  trained_year integer CHECK (trained_year IS NULL OR trained_year BETWEEN 1950 AND 2100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (application_id, kind)
);

COMMENT ON TABLE public.cleaner_application_trainings IS
  'CPR and cook training answers for a cleaner application. One row per application and kind.';

CREATE INDEX IF NOT EXISTS cleaner_application_trainings_user_id_idx
  ON public.cleaner_application_trainings (user_id);
