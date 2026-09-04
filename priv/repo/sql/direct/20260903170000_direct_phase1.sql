-- Instaclean Direct Phase 1 tables, copied from
-- molayodecker/instaclean-schema#98 and adapted for Mithril/Fly.
--
-- Included: tables, indexes, updated_at triggers, and the later provenance
-- constraint. Omitted: Supabase RLS, GRANT/REVOKE on anon/authenticated/
-- service_role, and compatibility RPCs. Mithril owns those operations.

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS public.placement_candidate_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  placement_opt_in boolean NOT NULL DEFAULT false,
  placement_status text NOT NULL DEFAULT 'inactive'
    CHECK (placement_status IN ('inactive', 'available', 'paused')),
  desired_roles text[] NOT NULL DEFAULT '{}'::text[]
    CHECK (
      desired_roles <@ ARRAY[
        'househelp', 'nanny', 'cleaner', 'elder_caregiver',
        'cook', 'driver', 'gardener'
      ]::text[]
    ),
  living_arrangements text[] NOT NULL DEFAULT '{}'::text[]
    CHECK (living_arrangements <@ ARRAY['live_in', 'live_out', 'flexible']::text[]),
  employment_types text[] NOT NULL DEFAULT '{}'::text[]
    CHECK (employment_types <@ ARRAY['full_time', 'part_time', 'flexible']::text[]),
  expected_salary_min_pesewas integer
    CHECK (expected_salary_min_pesewas IS NULL OR expected_salary_min_pesewas >= 0),
  expected_salary_max_pesewas integer
    CHECK (expected_salary_max_pesewas IS NULL OR expected_salary_max_pesewas >= 0),
  salary_frequency text
    CHECK (salary_frequency IS NULL OR salary_frequency IN ('hourly', 'daily', 'weekly', 'monthly')),
  preferred_languages text[] NOT NULL DEFAULT '{}'::text[],
  years_experience integer
    CHECK (years_experience IS NULL OR years_experience BETWEEN 0 AND 80),
  available_from date,
  bio text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT placement_candidate_profiles_salary_range_check
    CHECK (
      expected_salary_min_pesewas IS NULL
      OR expected_salary_max_pesewas IS NULL
      OR expected_salary_min_pesewas <= expected_salary_max_pesewas
    )
);

CREATE INDEX IF NOT EXISTS placement_candidate_profiles_opt_in_status_idx
  ON public.placement_candidate_profiles (placement_opt_in, placement_status);
CREATE INDEX IF NOT EXISTS placement_candidate_profiles_roles_gin_idx
  ON public.placement_candidate_profiles USING gin (desired_roles);

DROP TRIGGER IF EXISTS placement_candidate_profiles_set_updated_at ON public.placement_candidate_profiles;
CREATE TRIGGER placement_candidate_profiles_set_updated_at
BEFORE UPDATE ON public.placement_candidate_profiles
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.placement_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'matching', 'shortlisted', 'placed', 'cancelled', 'expired')),
  role text NOT NULL
    CHECK (role IN ('househelp', 'nanny', 'cleaner', 'elder_caregiver', 'cook', 'driver', 'gardener')),
  living_arrangement text NOT NULL DEFAULT 'flexible'
    CHECK (living_arrangement IN ('live_in', 'live_out', 'flexible')),
  employment_type text NOT NULL DEFAULT 'flexible'
    CHECK (employment_type IN ('full_time', 'part_time', 'flexible')),
  desired_start_date date,
  salary_min_pesewas integer
    CHECK (salary_min_pesewas IS NULL OR salary_min_pesewas >= 0),
  salary_max_pesewas integer
    CHECK (salary_max_pesewas IS NULL OR salary_max_pesewas >= 0),
  salary_frequency text
    CHECK (salary_frequency IS NULL OR salary_frequency IN ('hourly', 'daily', 'weekly', 'monthly')),
  household_address_snapshot text NOT NULL,
  latitude double precision
    CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  longitude double precision
    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  requirements jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(requirements) = 'object'),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT placement_requests_salary_range_check
    CHECK (
      salary_min_pesewas IS NULL
      OR salary_max_pesewas IS NULL
      OR salary_min_pesewas <= salary_max_pesewas
    )
);

CREATE INDEX IF NOT EXISTS placement_requests_customer_status_idx
  ON public.placement_requests (customer_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS placement_requests_status_updated_idx
  ON public.placement_requests (status, updated_at DESC);

DROP TRIGGER IF EXISTS placement_requests_set_updated_at ON public.placement_requests;
CREATE TRIGGER placement_requests_set_updated_at
BEFORE UPDATE ON public.placement_requests
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.placement_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  placement_request_id uuid NOT NULL REFERENCES public.placement_requests(id) ON DELETE CASCADE,
  candidate_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'suggested'
    CHECK (status IN ('suggested', 'selected', 'rejected', 'cancelled', 'hired')),
  match_score integer CHECK (match_score IS NULL OR match_score BETWEEN 0 AND 100),
  admin_notes text,
  customer_visible_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (placement_request_id, candidate_user_id)
);

CREATE INDEX IF NOT EXISTS placement_matches_request_status_idx
  ON public.placement_matches (placement_request_id, status);
CREATE INDEX IF NOT EXISTS placement_matches_candidate_idx
  ON public.placement_matches (candidate_user_id);

DROP TRIGGER IF EXISTS placement_matches_set_updated_at ON public.placement_matches;
CREATE TRIGGER placement_matches_set_updated_at
BEFORE UPDATE ON public.placement_matches
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.household_workers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_owner_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  worker_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  first_name text NOT NULL CHECK (btrim(first_name) <> ''),
  last_name text,
  phone text NOT NULL CHECK (btrim(phone) <> ''),
  email text,
  source text NOT NULL
    CHECK (source IN ('instaclean_placement', 'customer_invited')),
  placement_request_id uuid REFERENCES public.placement_requests(id) ON DELETE SET NULL,
  placement_match_id uuid REFERENCES public.placement_matches(id) ON DELETE SET NULL,
  role text
    CHECK (role IS NULL OR role IN ('househelp', 'nanny', 'cleaner', 'elder_caregiver', 'cook', 'driver', 'gardener')),
  start_date date,
  salary_amount_pesewas integer
    CHECK (salary_amount_pesewas IS NULL OR salary_amount_pesewas >= 0),
  salary_frequency text
    CHECK (salary_frequency IS NULL OR salary_frequency IN ('hourly', 'daily', 'weekly', 'monthly')),
  live_in boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'inactive', 'terminated')),
  invitation_status text NOT NULL DEFAULT 'not_sent'
    CHECK (invitation_status IN ('not_sent', 'pending', 'accepted', 'expired', 'revoked')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS household_workers_owner_linked_user_uniq
  ON public.household_workers (household_owner_id, worker_user_id)
  WHERE worker_user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS household_workers_owner_unlinked_phone_uniq
  ON public.household_workers (household_owner_id, phone)
  WHERE worker_user_id IS NULL;
CREATE INDEX IF NOT EXISTS household_workers_owner_status_idx
  ON public.household_workers (household_owner_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS household_workers_worker_idx
  ON public.household_workers (worker_user_id)
  WHERE worker_user_id IS NOT NULL;

DROP TRIGGER IF EXISTS household_workers_set_updated_at ON public.household_workers;
CREATE TRIGGER household_workers_set_updated_at
BEFORE UPDATE ON public.household_workers
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.household_workers
  DROP CONSTRAINT IF EXISTS household_workers_source_links_check;

ALTER TABLE public.household_workers
  ADD CONSTRAINT household_workers_source_links_check CHECK (
    source = 'instaclean_placement'
    OR (
      source = 'customer_invited'
      AND placement_request_id IS NULL
      AND placement_match_id IS NULL
    )
  );
