-- Book Now category sort weight (lower = shown earlier).
-- Canonical name matches service_types.weight. sort_order is kept in sync for older clients.

ALTER TABLE public.service_categories
  ADD COLUMN IF NOT EXISTS weight integer NOT NULL DEFAULT 100;

ALTER TABLE public.service_categories
  DROP CONSTRAINT IF EXISTS service_categories_weight_nonneg;

ALTER TABLE public.service_categories
  ADD CONSTRAINT service_categories_weight_nonneg CHECK (weight >= 0);

COMMENT ON COLUMN public.service_categories.weight IS
  'Book Now catalog sort weight; lower values appear first. Editable in Admin → Services.';

CREATE INDEX IF NOT EXISTS service_categories_weight_idx
  ON public.service_categories (weight, name);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'service_categories'
      AND column_name = 'sort_order'
  ) THEN
    UPDATE public.service_categories
    SET weight = sort_order
    WHERE sort_order IS NOT NULL;
  END IF;
END $$;

UPDATE public.service_categories SET weight = 10 WHERE slug = 'cleaning';
UPDATE public.service_categories SET weight = 20 WHERE slug = 'washing';
UPDATE public.service_categories SET weight = 30 WHERE slug = 'ironing';
UPDATE public.service_categories SET weight = 40 WHERE slug = 'airbnb';
UPDATE public.service_categories SET weight = 50 WHERE slug = 'quick_tasks';
UPDATE public.service_categories SET weight = 60 WHERE slug = 'caregiving';
UPDATE public.service_categories SET weight = 70 WHERE slug = 'pet_care';

CREATE OR REPLACE FUNCTION public.get_service_categories()
RETURNS TABLE(id bigint, name text, icon text, service_types jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN QUERY
    SELECT
      sc.id::bigint,
      sc.name,
      sc.icon,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id', st.id,
            'name', st.name,
            'price', st.price,
            'duration', st.duration
          )
        ) FILTER (WHERE st.id IS NOT NULL),
        '[]'::jsonb
      ) AS service_types
    FROM public.service_categories sc
    LEFT JOIN public.service_types st ON st.category_id = sc.id
    WHERE (st.active = true OR st.id IS NULL)
      AND (
        CASE COALESCE(sc.slug, '')
          WHEN 'caregiving' THEN public.is_care_pet_catalog_visible()
          WHEN 'pet_care' THEN public.is_care_pet_catalog_visible()
          WHEN 'airbnb' THEN public.is_airbnb_catalog_visible()
          WHEN 'quick_tasks' THEN public.is_quick_tasks_catalog_visible()
          WHEN 'cooks' THEN public.is_cooks_catalog_visible()
          WHEN 'drivers' THEN public.is_drivers_catalog_visible()
          ELSE true
        END
      )
    GROUP BY sc.id, sc.name, sc.icon, sc.weight
    ORDER BY sc.weight ASC, sc.name ASC;
END;
$function$;

COMMENT ON FUNCTION public.get_service_categories() IS
  'Active service catalog ordered by weight; gated categories omitted while their Book Now flags are off.';
