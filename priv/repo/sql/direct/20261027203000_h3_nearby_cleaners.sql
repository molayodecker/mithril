-- Index cleaner supply the way Uber indexes drivers.
--
-- Each base location is one neighborhood hex (resolution 8, about 0.74 km²).
-- A search builds the disk of hexes that covers the requested radius, then
-- the existing meter check still decides who is actually close enough.
-- Servers without the h3 extension keep the geography search unchanged.

SELECT EXISTS (
  SELECT 1
  FROM pg_available_extensions
  WHERE name = 'h3'
) AS h3_available \gset

\if :h3_available
CREATE EXTENSION IF NOT EXISTS h3;

CREATE OR REPLACE FUNCTION public.h3_dispatch_resolution()
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT 8;
$$;

COMMENT ON FUNCTION public.h3_dispatch_resolution() IS
  'Neighborhood hex for cleaner supply. Resolution 8 is about 0.74 km².';

CREATE OR REPLACE FUNCTION public.h3_cell_for_lat_lng(
  p_latitude double precision,
  p_longitude double precision
)
RETURNS h3index
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_latitude IS NULL OR p_longitude IS NULL THEN NULL
    WHEN p_latitude < -90 OR p_latitude > 90 THEN NULL
    WHEN p_longitude < -180 OR p_longitude > 180 THEN NULL
    ELSE h3_latlng_to_cell(
      POINT(p_longitude, p_latitude),
      public.h3_dispatch_resolution()
    )
  END;
$$;

COMMENT ON FUNCTION public.h3_cell_for_lat_lng(double precision, double precision) IS
  'H3 cell for a latitude and longitude. POINT stores longitude first.';

CREATE OR REPLACE FUNCTION public.h3_dispatch_k(p_radius_meters integer)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_radius_meters IS NULL OR p_radius_meters <= 0 THEN 0
    ELSE CEIL(
      p_radius_meters::numeric
      / h3_get_hexagon_edge_length_avg(public.h3_dispatch_resolution(), 'm')
    )::integer + 1
  END;
$$;

COMMENT ON FUNCTION public.h3_dispatch_k(integer) IS
  'Hex rings needed so the disk covers p_radius_meters, plus one ring of margin.';

CREATE OR REPLACE FUNCTION public.h3_dispatch_disk(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_meters integer
)
RETURNS SETOF h3index
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT h3_grid_disk(origin.cell, origin.k)
  FROM (
    SELECT
      public.h3_cell_for_lat_lng(p_latitude, p_longitude) AS cell,
      public.h3_dispatch_k(p_radius_meters) AS k
  ) AS origin
  WHERE origin.cell IS NOT NULL
    AND origin.k > 0;
$$;

COMMENT ON FUNCTION public.h3_dispatch_disk(double precision, double precision, integer) IS
  'Candidate hexes around a job. Exact distance is still applied after this set.';

SELECT EXISTS (
  SELECT 1
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name = 'cleaner_data'
) AS cleaner_data_exists \gset

SELECT EXISTS (
  SELECT 1
  FROM pg_extension
  WHERE extname = 'postgis'
) AS postgis_available \gset

\if :cleaner_data_exists
\if :postgis_available
ALTER TABLE public.cleaner_data
  ADD COLUMN IF NOT EXISTS base_h3_cell h3index;

CREATE INDEX IF NOT EXISTS cleaner_data_base_h3_cell_idx
  ON public.cleaner_data (base_h3_cell);

CREATE OR REPLACE FUNCTION public.cleaner_data_set_base_h3_cell()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.base_location IS NULL THEN
    NEW.base_h3_cell := NULL;
  ELSE
    NEW.base_h3_cell := public.h3_cell_for_lat_lng(
      ST_Y(NEW.base_location),
      ST_X(NEW.base_location)
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cleaner_data_set_base_h3_cell ON public.cleaner_data;
CREATE TRIGGER cleaner_data_set_base_h3_cell
BEFORE INSERT OR UPDATE OF base_location
ON public.cleaner_data
FOR EACH ROW
EXECUTE FUNCTION public.cleaner_data_set_base_h3_cell();

UPDATE public.cleaner_data
SET base_h3_cell = public.h3_cell_for_lat_lng(
  ST_Y(base_location),
  ST_X(base_location)
)
WHERE base_location IS NOT NULL
  AND base_h3_cell IS DISTINCT FROM public.h3_cell_for_lat_lng(
    ST_Y(base_location),
    ST_X(base_location)
  );

CREATE OR REPLACE FUNCTION public.get_nearby_available_cleaners(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_meters integer,
  p_scheduled_date date,
  p_start_time time without time zone,
  p_duration_hours integer
)
RETURNS TABLE(
  id uuid,
  fullname text,
  avatar_url text,
  distance_meters double precision,
  rating double precision
)
LANGUAGE sql
STABLE
AS $$
WITH
origin AS (
  SELECT ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography AS g
),
booking AS (
  SELECT tstzrange(
    (p_scheduled_date + p_start_time)::timestamptz,
    (p_scheduled_date + p_start_time + (p_duration_hours || ' hours')::interval)::timestamptz,
    '[)'
  ) AS r
),
disk AS (
  SELECT public.h3_dispatch_disk(p_latitude, p_longitude, p_radius_meters) AS cell
),
cleaners AS (
  SELECT
    p.id,
    p.fullname,
    p.avatar_url,
    cd.rating,
    cd.max_travel_distance_meters,
    cd.base_h3_cell,
    COALESCE(cd.base_location::geography, p.location_wkt) AS effective_location
  FROM public.profiles p
  JOIN public.cleaner_data cd
    ON cd.user_id = p.id
  WHERE COALESCE(cd.base_location::geography, p.location_wkt) IS NOT NULL
    AND cd.status = 'active'::public.cleaner_status
    AND cd.verified = true
    AND COALESCE(cd.is_online, false) = true
    AND EXISTS (
      SELECT 1
      FROM public.user_roles ur
      WHERE ur.user_id = p.id
        AND ur.role_id = 'cleaner'
    )
)
SELECT
  c.id,
  c.fullname,
  c.avatar_url,
  d.distance_meters,
  c.rating::double precision AS rating
FROM cleaners c
CROSS JOIN origin o
CROSS JOIN booking bk
CROSS JOIN LATERAL (
  SELECT ST_Distance(c.effective_location, o.g) AS distance_meters
) d
WHERE ST_DWithin(c.effective_location, o.g, p_radius_meters)
  AND d.distance_meters <= COALESCE(c.max_travel_distance_meters, 30000)
  AND (
    c.base_h3_cell IN (SELECT disk.cell FROM disk)
    OR (
      c.base_h3_cell IS NULL
      AND public.h3_cell_for_lat_lng(
        ST_Y(c.effective_location::geometry),
        ST_X(c.effective_location::geometry)
      ) IN (SELECT disk.cell FROM disk)
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.bookings b
    WHERE b.cleaner_id = c.id
      AND b.status <> 'cancelled'::public.booking_status
      AND b.booking_period && bk.r
  )
ORDER BY d.distance_meters ASC
LIMIT 200;
$$;
\endif
\endif
\endif
