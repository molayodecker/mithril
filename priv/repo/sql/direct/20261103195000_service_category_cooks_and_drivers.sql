-- Production's service_category enum stopped at pet_care. Role services need cooks and drivers.
-- New enum values commit before the later service inserts. Safe to run again.

ALTER TYPE public.service_category ADD VALUE IF NOT EXISTS 'cooks';
ALTER TYPE public.service_category ADD VALUE IF NOT EXISTS 'drivers';

INSERT INTO public.service_categories (name, slug, icon, weight, description)
SELECT 'Driver', 'drivers', 'car', 80, 'Driving for passengers, deliveries, or equipment.'
WHERE NOT EXISTS (
  SELECT 1
  FROM public.service_categories AS existing
  WHERE existing.slug = 'drivers'
);
