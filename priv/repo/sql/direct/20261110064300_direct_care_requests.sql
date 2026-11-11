-- Customer Direct requests (family care, pet care, drivers) and the worker inbox.
--
-- list_direct_requests_for_worker is allowlisted by the mobile gateway. Without
-- this function Postgres lookup returns unknown_function and the worker app
-- reports it. A worker sees only open requests matched to their offered specialty.

CREATE TABLE IF NOT EXISTS public.direct_care_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  specialty_slug text NOT NULL,
  category text NOT NULL,
  frequency text NOT NULL,
  location_label text NOT NULL,
  notes text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  budget_amount_minor integer,
  budget_unit text,
  budget_negotiable boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'closed', 'cancelled')),
  latitude double precision,
  longitude double precision,
  timezone_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_care_requests_details_object CHECK (jsonb_typeof(details) = 'object')
);

CREATE INDEX IF NOT EXISTS direct_care_requests_customer_idx
  ON public.direct_care_requests (customer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.direct_care_request_matches (
  care_request_id uuid NOT NULL REFERENCES public.direct_care_requests(id) ON DELETE CASCADE,
  worker_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (care_request_id, worker_user_id)
);

CREATE INDEX IF NOT EXISTS direct_care_request_matches_worker_idx
  ON public.direct_care_request_matches (worker_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.direct_care_request_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  care_request_id uuid NOT NULL REFERENCES public.direct_care_requests(id) ON DELETE CASCADE,
  worker_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  offer_kind text NOT NULL CHECK (offer_kind IN ('accept', 'counter')),
  amount_minor integer,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (care_request_id, worker_user_id)
);

DROP FUNCTION IF EXISTS public.create_direct_request(
  text, text, text, numeric, text, boolean, text, double precision, double precision, text, text, jsonb
);
CREATE FUNCTION public.create_direct_request(
  p_category text,
  p_service_slug text,
  p_frequency text,
  p_budget_amount_major numeric,
  p_budget_unit text,
  p_budget_negotiable boolean,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_timezone_name text,
  p_notes text,
  p_details jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  request_id uuid;
  specialty text := lower(btrim(COALESCE(p_service_slug, '')));
  location text := btrim(COALESCE(p_location_label, ''));
  amount_minor integer;
BEGIN
  IF caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  IF specialty !~ '^[a-z][a-z0-9_]{1,63}$'
     OR btrim(COALESCE(p_category, '')) = ''
     OR btrim(COALESCE(p_frequency, '')) = ''
     OR btrim(COALESCE(p_budget_unit, '')) = ''
     OR location = ''
     OR p_budget_amount_major IS NULL
     OR p_budget_amount_major < 0
     OR p_budget_amount_major > 10000000
     OR (p_details IS NOT NULL AND jsonb_typeof(p_details) <> 'object') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_draft');
  END IF;

  amount_minor := round(p_budget_amount_major * 100)::integer;

  INSERT INTO public.direct_care_requests (
    customer_id, specialty_slug, category, frequency, location_label, notes, details,
    budget_amount_minor, budget_unit, budget_negotiable, latitude, longitude, timezone_name
  ) VALUES (
    caller,
    specialty,
    btrim(p_category),
    btrim(p_frequency),
    location,
    NULLIF(btrim(COALESCE(p_notes, '')), ''),
    COALESCE(p_details, '{}'::jsonb),
    amount_minor,
    btrim(p_budget_unit),
    COALESCE(p_budget_negotiable, false),
    p_latitude,
    p_longitude,
    NULLIF(btrim(COALESCE(p_timezone_name, '')), '')
  )
  RETURNING id INTO request_id;

  INSERT INTO public.direct_care_request_matches (care_request_id, worker_user_id)
  SELECT request_id, cd.user_id
  FROM public.cleaner_data cd
  WHERE cd.user_id <> caller
    AND cd.verified IS TRUE
    AND cd.status = 'active'
    AND EXISTS (
      SELECT 1
      FROM unnest(COALESCE(cd.specialties, '{}'::text[])) AS offered(slug)
      WHERE lower(btrim(offered.slug)) = specialty
    )
  ORDER BY cd.user_id
  LIMIT 25;

  RETURN jsonb_build_object('success', true, 'care_request_id', request_id);
END;
$$;

DROP FUNCTION IF EXISTS public.list_direct_requests_for_worker();
CREATE FUNCTION public.list_direct_requests_for_worker()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  requests jsonb;
BEGIN
  IF caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'customer_id', r.customer_id,
        'specialty_slug', r.specialty_slug,
        'category', r.category,
        'frequency', r.frequency,
        'location_label', r.location_label,
        'notes', r.notes,
        'details', r.details,
        'budget_amount_minor', r.budget_amount_minor,
        'budget_unit', r.budget_unit,
        'budget_negotiable', r.budget_negotiable,
        'status', r.status,
        'created_at', r.created_at
      )
      ORDER BY r.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO requests
  FROM public.direct_care_requests r
  JOIN public.direct_care_request_matches m
    ON m.care_request_id = r.id
   AND m.worker_user_id = caller
  WHERE r.status = 'submitted'
    AND EXISTS (
      SELECT 1 FROM public.cleaner_data cd
      WHERE cd.user_id = caller
        AND cd.verified IS TRUE
        AND cd.status = 'active'
        AND EXISTS (
          SELECT 1 FROM unnest(COALESCE(cd.specialties, '{}'::text[])) AS offered(slug)
          WHERE lower(btrim(offered.slug)) = r.specialty_slug
        )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_care_request_responses response
      WHERE response.care_request_id = r.id
        AND response.worker_user_id = caller
    );

  RETURN jsonb_build_object('success', true, 'requests', requests);
END;
$$;

DROP FUNCTION IF EXISTS public.get_direct_request(uuid);
CREATE FUNCTION public.get_direct_request(p_care_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  request jsonb;
BEGIN
  IF caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  SELECT jsonb_build_object(
    'id', r.id,
    'customer_id', r.customer_id,
    'specialty_slug', r.specialty_slug,
    'category', r.category,
    'frequency', r.frequency,
    'location_label', r.location_label,
    'notes', r.notes,
    'details', r.details,
    'budget_amount_minor', r.budget_amount_minor,
    'budget_unit', r.budget_unit,
    'budget_negotiable', r.budget_negotiable,
    'status', r.status,
    'created_at', r.created_at,
    'responses', CASE WHEN r.customer_id = caller THEN COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'worker_user_id', response.worker_user_id,
          'offer_kind', response.offer_kind,
          'amount_minor', response.amount_minor,
          'note', response.note,
          'created_at', response.created_at
        ) ORDER BY response.created_at DESC
      )
      FROM public.direct_care_request_responses response
      WHERE response.care_request_id = r.id
    ), '[]'::jsonb) ELSE '[]'::jsonb END
  )
  INTO request
  FROM public.direct_care_requests r
  WHERE r.id = p_care_request_id
    AND (
      r.customer_id = caller
      OR EXISTS (
        SELECT 1
        FROM public.direct_care_request_matches m
        WHERE m.care_request_id = r.id
          AND m.worker_user_id = caller
          AND r.status = 'submitted'
          AND EXISTS (
            SELECT 1 FROM public.cleaner_data cd
            WHERE cd.user_id = caller
              AND cd.verified IS TRUE
              AND cd.status = 'active'
              AND EXISTS (
                SELECT 1 FROM unnest(COALESCE(cd.specialties, '{}'::text[])) AS offered(slug)
                WHERE lower(btrim(offered.slug)) = r.specialty_slug
              )
          )
      )
    );

  IF request IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_found');
  END IF;

  RETURN jsonb_build_object('success', true, 'request', request);
END;
$$;

DROP FUNCTION IF EXISTS public.respond_to_care_request(uuid, text, numeric, text);
CREATE FUNCTION public.respond_to_care_request(
  p_care_request_id uuid,
  p_offer_kind text,
  p_amount_major numeric,
  p_note text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  kind text := lower(btrim(COALESCE(p_offer_kind, '')));
  amount_minor integer;
BEGIN
  IF caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  IF kind NOT IN ('accept', 'counter') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_offer');
  END IF;

  IF kind = 'counter' AND (
    p_amount_major IS NULL OR p_amount_major < 0 OR p_amount_major > 10000000
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_offer');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.direct_care_request_matches m
    JOIN public.direct_care_requests r ON r.id = m.care_request_id
    WHERE m.care_request_id = p_care_request_id
      AND m.worker_user_id = caller
      AND r.status = 'submitted'
      AND EXISTS (
      SELECT 1 FROM public.cleaner_data cd
      WHERE cd.user_id = caller
        AND cd.verified IS TRUE
        AND cd.status = 'active'
        AND EXISTS (
          SELECT 1 FROM unnest(COALESCE(cd.specialties, '{}'::text[])) AS offered(slug)
          WHERE lower(btrim(offered.slug)) = r.specialty_slug
        )
    )
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_found');
  END IF;

  amount_minor := CASE
    WHEN p_amount_major IS NULL THEN NULL
    ELSE round(p_amount_major * 100)::integer
  END;

  INSERT INTO public.direct_care_request_responses (
    care_request_id, worker_user_id, offer_kind, amount_minor, note
  ) VALUES (
    p_care_request_id,
    caller,
    kind,
    amount_minor,
    NULLIF(btrim(COALESCE(p_note, '')), '')
  )
  ON CONFLICT (care_request_id, worker_user_id) DO NOTHING;

  RETURN jsonb_build_object('success', true);
END;
$$;

COMMENT ON FUNCTION public.list_direct_requests_for_worker() IS
  'Open Direct requests matched to the signed-in worker. Omits coordinates.';

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.create_direct_request(text, text, text, numeric, text, boolean, text, double precision, double precision, text, text, jsonb) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.list_direct_requests_for_worker() FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.get_direct_request(uuid) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.respond_to_care_request(uuid, text, numeric, text) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.create_direct_request(text, text, text, numeric, text, boolean, text, double precision, double precision, text, text, jsonb) TO authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.list_direct_requests_for_worker() TO authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_direct_request(uuid) TO authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.respond_to_care_request(uuid, text, numeric, text) TO authenticated';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping direct care request grants: %', SQLERRM;
END $$;
