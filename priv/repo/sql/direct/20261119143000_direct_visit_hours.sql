-- Billable visit length from bedrooms and bathrooms.
--
-- This is the same room formula the customer app uses. Concierge bookings
-- call this function and then price the returned hours. They do not calculate
-- the length themselves.
--
-- 2 hours + (bedrooms * 0.4) + (bathrooms * 0.23), snapped to the service
-- step and clamped to that service's minimum and maximum. Room counts outside
-- 1..10 are clamped. A missing service uses a 2 hour minimum, a 10 hour
-- maximum, and a 0.5 hour step. The final length is also capped at 10 hours.

CREATE OR REPLACE FUNCTION public.direct_visit_hours(
  p_bedrooms integer,
  p_bathrooms integer,
  p_service_id integer DEFAULT NULL
)
RETURNS TABLE(duration_hours numeric, home_size text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  bedroom_count integer;
  bathroom_count integer;
  min_hours numeric;
  max_hours numeric;
  step_hours numeric;
  home_hours numeric;
  base_hours numeric;
  stepped numeric;
  capped numeric;
  checked numeric;
BEGIN
  bedroom_count := least(10, greatest(1, COALESCE(p_bedrooms, 1)));
  bathroom_count := least(10, greatest(1, COALESCE(p_bathrooms, 1)));

  SELECT
    NULLIF(st.minimum_duration_hours, 0),
    NULLIF(st.maximum_duration_hours, 0),
    NULLIF(st.duration_increment_hours, 0)
  INTO min_hours, max_hours, step_hours
  FROM public.service_types st
  WHERE st.id = p_service_id;

  min_hours := COALESCE(min_hours, 2);
  max_hours := GREATEST(min_hours, COALESCE(max_hours, 10));
  step_hours := COALESCE(step_hours, 0.5);

  home_hours := round(2 + (bedroom_count * 0.4) + (bathroom_count * 0.23), 2);
  base_hours := GREATEST(min_hours, home_hours);
  stepped := round(base_hours / step_hours) * step_hours;
  capped := LEAST(max_hours, stepped);

  IF capped < min_hours OR capped > max_hours THEN
    checked := capped;
  ELSE
    checked := round(capped / step_hours) * step_hours;
  END IF;

  max_hours := LEAST(max_hours, 10);
  checked := GREATEST(min_hours, LEAST(max_hours, checked));

  -- The service step was applied above. Re-rounding to half-hours here can
  -- violate non-half-hour service limits (for example, 3.2 or 3.25 hours).
  duration_hours := checked;
  home_size := bedroom_count::text || ' bed, ' || bathroom_count::text || ' bath';
  RETURN NEXT;
END;
$$;
