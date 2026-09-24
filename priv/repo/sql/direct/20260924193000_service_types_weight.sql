-- Customer booking catalog sort weight (lower = shown earlier).
ALTER TABLE public.service_types
  ADD COLUMN IF NOT EXISTS weight integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.service_types.weight IS
  'Sort weight for customer booking lists; lower values appear first within a category.';

-- One-time rename if an earlier dev migration added display_order.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'service_types'
      AND column_name = 'display_order'
  ) THEN
    UPDATE public.service_types
    SET weight = display_order
    WHERE weight = 0 AND display_order <> 0;

    ALTER TABLE public.service_types DROP COLUMN display_order;
  END IF;
END $$;

-- Default cleaning catalog weights (no-op when slug missing).
UPDATE public.service_types
SET weight = ordered.sort_weight
FROM (
  VALUES
    ('regular_cleaning', 10),
    ('deep_cleaning', 20),
    ('move_in_out_cleaning', 30),
    ('office_cleaning', 40),
    ('post_construction_cleaning', 50),
    ('eco_friendly_cleaning', 60)
) AS ordered (slug, sort_weight)
WHERE active = true
  AND category = 'cleaning'
  AND lower(replace(coalesce(specialty_slug, ''), '-', '_')) = ordered.slug;
