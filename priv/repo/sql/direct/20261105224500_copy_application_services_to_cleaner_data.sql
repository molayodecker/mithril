-- Approval already creates cleaner_data. It did not copy the application's
-- bookable services, so Services you offer tried to update cleaner_data from
-- the phone. The mobile gateway rejects that write with `forbidden`.
-- Copy service_type_ids onto specialties when a worker is approved, and let
-- the signed-in worker change that list through an RPC. Safe to run again.

CREATE OR REPLACE FUNCTION public.copy_application_services_to_cleaner_data(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids integer[];
  v_specialties text[];
  v_categories public.service_category[];
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.cleaner_data WHERE user_id = p_user_id) THEN
    RETURN;
  END IF;

  -- A worker who already confirmed services keeps that list.
  IF EXISTS (
    SELECT 1
    FROM public.cleaner_data
    WHERE user_id = p_user_id
      AND specialties IS NOT NULL
      AND cardinality(specialties) > 0
  ) THEN
    RETURN;
  END IF;

  SELECT ca.service_type_ids
  INTO v_ids
  FROM public.cleaner_applications ca
  WHERE ca.user_id = p_user_id
    AND ca.service_type_ids IS NOT NULL
    AND cardinality(ca.service_type_ids) > 0
  ORDER BY (ca.status::text = 'approved') DESC, ca.updated_at DESC NULLS LAST
  LIMIT 1;

  IF v_ids IS NULL OR cardinality(v_ids) = 0 THEN
    RETURN;
  END IF;

  SELECT
    COALESCE(
      array_agg(DISTINCT lower(btrim(st.specialty_slug))) FILTER (
        WHERE st.specialty_slug IS NOT NULL
          AND btrim(st.specialty_slug) <> ''
          AND lower(btrim(st.specialty_slug)) <> 'quick_tasks'
          AND lower(btrim(st.specialty_slug)) ~ '^[a-z][a-z0-9_]{1,63}$'
      ),
      '{}'::text[]
    ),
    COALESCE(
      array_agg(DISTINCT st.category) FILTER (
        WHERE st.category IS NOT NULL
          AND lower(btrim(COALESCE(st.specialty_slug, ''))) <> 'quick_tasks'
      ),
      '{}'::public.service_category[]
    )
  INTO v_specialties, v_categories
  FROM public.service_types st
  WHERE st.id = ANY (v_ids);

  IF v_specialties IS NULL OR cardinality(v_specialties) = 0 THEN
    RETURN;
  END IF;

  UPDATE public.cleaner_data
  SET specialties = v_specialties,
      service_categories = v_categories,
      updated_at = now()
  WHERE user_id = p_user_id
    AND (specialties IS NULL OR cardinality(specialties) = 0);
END;
$$;

COMMENT ON FUNCTION public.copy_application_services_to_cleaner_data(uuid) IS
  'Copies the latest application service_type_ids onto an existing cleaner_data row when specialties are still empty. Does not insert a cleaner_data row and does not overwrite a confirmed list.';

CREATE OR REPLACE FUNCTION public.copy_application_services_on_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.user_id IS NOT NULL
     AND NEW.status::text = 'approved'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM public.copy_application_services_to_cleaner_data(NEW.user_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_copy_application_services_on_approval ON public.cleaner_applications;
CREATE TRIGGER trg_copy_application_services_on_approval
AFTER INSERT OR UPDATE OF status ON public.cleaner_applications
FOR EACH ROW
EXECUTE FUNCTION public.copy_application_services_on_approval();

CREATE OR REPLACE FUNCTION public.copy_my_application_services()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  v_specialties jsonb;
  v_categories jsonb;
BEGIN
  IF caller IS NULL THEN
    RETURN jsonb_build_object(
      'specialties', '[]'::jsonb,
      'serviceCategories', '[]'::jsonb
    );
  END IF;

  PERFORM public.copy_application_services_to_cleaner_data(caller);

  SELECT
    COALESCE(to_jsonb(cd.specialties), '[]'::jsonb),
    COALESCE(to_jsonb(cd.service_categories), '[]'::jsonb)
  INTO v_specialties, v_categories
  FROM public.cleaner_data cd
  WHERE cd.user_id = caller;

  RETURN jsonb_build_object(
    'specialties', COALESCE(v_specialties, '[]'::jsonb),
    'serviceCategories', COALESCE(v_categories, '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION public.copy_my_application_services() IS
  'Signed-in repair for an approval that left cleaner_data.specialties empty. Returns the specialties now stored for auth.uid().';

CREATE OR REPLACE FUNCTION public.update_my_offered_specialties(p_specialties text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  v_specialties text[];
  v_categories public.service_category[];
BEGIN
  IF caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  PERFORM 1 FROM public.users WHERE id = caller FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.cleaner_data WHERE user_id = caller) THEN
    RETURN jsonb_build_object('success', false, 'error', 'cleaner_not_found');
  END IF;

  SELECT COALESCE(array_agg(DISTINCT slug), '{}'::text[])
  INTO v_specialties
  FROM (
    SELECT lower(btrim(raw_slug)) AS slug
    FROM unnest(COALESCE(p_specialties, '{}'::text[])) AS raw_slug
  ) normalized
  WHERE slug ~ '^[a-z][a-z0-9_]{1,63}$'
    AND slug <> 'quick_tasks'
    AND (
      EXISTS (
        SELECT 1
        FROM public.service_types st
        WHERE lower(btrim(st.specialty_slug)) = slug
      )
      OR EXISTS (
        SELECT 1
        FROM public.micro_tasks mt
        WHERE lower(btrim(mt.required_specialty_slug)) = slug
      )
    );

  IF v_specialties IS NULL OR cardinality(v_specialties) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'empty');
  END IF;

  SELECT COALESCE(array_agg(DISTINCT category), '{}'::public.service_category[])
  INTO v_categories
  FROM (
    SELECT st.category
    FROM public.service_types st
    WHERE lower(btrim(st.specialty_slug)) = ANY (v_specialties)
      AND st.category IS NOT NULL
    UNION
    SELECT 'quick_tasks'::public.service_category
    FROM unnest(v_specialties) AS slug
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.service_types st
      WHERE lower(btrim(st.specialty_slug)) = slug
    )
  ) categories;

  UPDATE public.cleaner_data
  SET specialties = v_specialties,
      service_categories = v_categories,
      updated_at = now()
  WHERE user_id = caller;

  RETURN jsonb_build_object('success', true);
END;
$$;

COMMENT ON FUNCTION public.update_my_offered_specialties(text[]) IS
  'Replaces the signed-in worker''s offered specialties. Categories are derived from the catalog. Requires an existing cleaner_data row.';

-- Workers approved before this copy existed still have an empty specialties list.
DO $$
DECLARE
  target_user uuid;
BEGIN
  FOR target_user IN
    SELECT cd.user_id
    FROM public.cleaner_data cd
    WHERE cd.specialties IS NULL OR cardinality(cd.specialties) = 0
  LOOP
    PERFORM public.copy_application_services_to_cleaner_data(target_user);
  END LOOP;
END $$;

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.copy_application_services_to_cleaner_data(uuid) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.copy_application_services_on_approval() FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.copy_my_application_services() FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.update_my_offered_specialties(text[]) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.copy_my_application_services() TO authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.update_my_offered_specialties(text[]) TO authenticated';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MPG system roles%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'skipping application service copy grants: %', SQLERRM;
END $$;
