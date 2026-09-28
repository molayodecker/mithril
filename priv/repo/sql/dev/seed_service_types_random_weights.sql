-- DEV / STAGING ONLY — do not run on production.
-- Requires: priv/repo/sql/direct/20260924193000_service_types_weight.sql applied first.
--
-- Assigns a random sort order to every active service type (weight 10, 20, 30, …
-- in a shuffled row order) so Book Now and the booking modal reflect weight sorting.
--
--   psql "$DATABASE_URL" -f priv/repo/sql/dev/seed_service_types_random_weights.sql

UPDATE public.service_types AS service_type
SET weight = ranked.shuffle_weight
FROM (
  SELECT
    id,
    (ROW_NUMBER() OVER (ORDER BY random()) * 10)::integer AS shuffle_weight
  FROM public.service_types
  WHERE active = true
) AS ranked
WHERE service_type.id = ranked.id;

-- Optional: inspect result
-- SELECT id, name, category, specialty_slug, weight
-- FROM public.service_types
-- WHERE active = true
-- ORDER BY weight, name;
