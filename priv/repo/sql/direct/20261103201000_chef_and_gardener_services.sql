-- Bookable services for worker roles that had none.
-- Chef: Private Chef and Event Chef (cooks). Gardener: Lawn Care and Garden Care (quick tasks).
-- Prices are GHS in the same list-price unit as Home Cooking (80). Safe to run again.

INSERT INTO public.service_types (
  category_id,
  name,
  price,
  duration,
  category,
  active,
  features,
  specialty_slug,
  minimum_duration_hours,
  maximum_duration_hours,
  duration_increment_hours,
  description,
  weight
)
SELECT
  category.id,
  seed.name,
  seed.price,
  seed.duration,
  seed.service_category::public.service_category,
  true,
  seed.features,
  seed.specialty_slug,
  seed.minimum_duration_hours,
  seed.maximum_duration_hours,
  seed.duration_increment_hours,
  seed.description,
  0
FROM (
  VALUES
    (
      'cooks'::text,
      'Private Chef'::text,
      120::numeric,
      '3'::text,
      'cooks'::text,
      ARRAY[
        'Menu planned with the household',
        'Meals cooked in your kitchen',
        'Dietary notes followed',
        'Kitchen left tidy'
      ]::text[],
      'private_chef'::text,
      2::numeric,
      8::numeric,
      1::numeric,
      'A private chef cooks for your household.'::text
    ),
    (
      'cooks',
      'Event Chef',
      160,
      '4',
      'cooks',
      ARRAY[
        'Menu agreed before the event',
        'Cooking and service for the guest count',
        'Dietary notes followed',
        'Kitchen left tidy'
      ]::text[],
      'event_chef',
      3,
      10,
      1,
      'A chef cooks for a gathering or event.'
    ),
    (
      'quick_tasks',
      'Lawn Care',
      70,
      '2',
      'quick_tasks',
      ARRAY[
        'Mowing and edging',
        'Clippings cleared',
        'Basic outdoor tidy'
      ]::text[],
      'lawn_care',
      1,
      6,
      0.5,
      'Lawn mowing and basic outdoor care.'
    ),
    (
      'quick_tasks',
      'Garden Care',
      80,
      '2',
      'quick_tasks',
      ARRAY[
        'Weeding and trimming',
        'Beds and paths tidied',
        'Green waste cleared'
      ]::text[],
      'garden_care',
      1,
      6,
      0.5,
      'Garden beds, plants, and outdoor upkeep.'
    )
) AS seed (
  category_slug,
  name,
  price,
  duration,
  service_category,
  features,
  specialty_slug,
  minimum_duration_hours,
  maximum_duration_hours,
  duration_increment_hours,
  description
)
JOIN public.service_categories AS category
  ON category.slug = seed.category_slug
WHERE NOT EXISTS (
  SELECT 1
  FROM public.service_types AS existing
  WHERE existing.specialty_slug = seed.specialty_slug
);
