-- Job-title services for chef, cook, gardener, housekeeper, driver, and nanny.
-- Hides the earlier Private Chef, Event Chef, Lawn Care, and Garden Care placeholders.
-- Prices are starting GHS list prices in the same unit as Home Cooking (80). Safe to run again.

UPDATE public.service_types
SET active = false
WHERE specialty_slug IN ('private_chef', 'event_chef', 'lawn_care', 'garden_care');

INSERT INTO public.service_categories (name, slug, icon, weight, description)
SELECT seed.name, seed.slug, seed.icon, seed.weight, seed.description
FROM (
  VALUES
    ('Chef', 'chef', 'chef-hat', 64, 'A chef working a kitchen station or leading the brigade.'),
    ('Cook', 'cook', 'pot-steam', 66, 'A cook preparing meals on the line or in advance.'),
    ('Gardener', 'gardener', 'flower', 72, 'Garden, grounds, and landscape work.'),
    ('Housekeeping', 'housekeeping', 'home', 68, 'Housekeeping for a home or guest rooms.'),
    ('Nanny', 'nanny', 'account-heart', 62, 'Child care in the home, including nights and travel.')
) AS seed(name, slug, icon, weight, description)
WHERE NOT EXISTS (
  SELECT 1 FROM public.service_categories AS existing WHERE existing.slug = seed.slug
);

INSERT INTO public.service_types (
  category_id, name, price, duration, category, active, features, specialty_slug,
  minimum_duration_hours, maximum_duration_hours, duration_increment_hours, description, weight
)
SELECT
  category.id,
  seed.name,
  seed.price,
  seed.duration,
  seed.service_category::public.service_category,
  true,
  ARRAY[]::text[],
  seed.specialty_slug,
  seed.minimum_duration_hours,
  seed.maximum_duration_hours,
  seed.duration_increment_hours,
  seed.description,
  seed.weight
FROM (
  VALUES
    ('chef', 'Executive Chef', 120::numeric, '3', 'cooks', 'executive_chef', 2::numeric, 8::numeric, 1::numeric, 'A chef working a kitchen station or leading the brigade.', 200),
    ('chef', 'Sous Chef', 120, '3', 'cooks', 'sous_chef', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 201),
    ('chef', 'Chef de Partie', 120, '3', 'cooks', 'chef_de_partie', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 202),
    ('chef', 'Commis Chef', 120, '3', 'cooks', 'commis_chef', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 203),
    ('chef', 'Saucier', 120, '3', 'cooks', 'saucier', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 204),
    ('chef', 'Poissonnier', 120, '3', 'cooks', 'poissonnier', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 205),
    ('chef', 'Grillardin', 120, '3', 'cooks', 'grillardin', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 206),
    ('chef', 'Friturier', 120, '3', 'cooks', 'friturier', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 207),
    ('chef', 'Rôtisseur', 120, '3', 'cooks', 'rotisseur', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 208),
    ('chef', 'Entremetier', 120, '3', 'cooks', 'entremetier', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 209),
    ('chef', 'Garde Manger', 120, '3', 'cooks', 'garde_manger', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 210),
    ('chef', 'Boucher', 120, '3', 'cooks', 'boucher', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 211),
    ('chef', 'Tournant', 120, '3', 'cooks', 'tournant', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 212),
    ('chef', 'Pâtissier', 120, '3', 'cooks', 'patissier', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 213),
    ('chef', 'Chocolatier', 120, '3', 'cooks', 'chocolatier', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 214),
    ('chef', 'Sushi Chef', 120, '3', 'cooks', 'sushi_chef', 2, 8, 1, 'A chef working a kitchen station or leading the brigade.', 215),
    ('cook', 'Line Cook', 80, '3', 'cooks', 'line_cook', 2, 8, 1, 'A cook preparing meals on the line or in advance.', 216),
    ('cook', 'Prep Cook', 80, '3', 'cooks', 'prep_cook', 2, 8, 1, 'A cook preparing meals on the line or in advance.', 217),
    ('cook', 'Short-Order Cook', 80, '3', 'cooks', 'short_order_cook', 2, 8, 1, 'A cook preparing meals on the line or in advance.', 218),
    ('cook', 'Institution Cook', 80, '3', 'cooks', 'institution_cook', 2, 8, 1, 'A cook preparing meals on the line or in advance.', 219),
    ('gardener', 'Landscape Architect', 70, '2', 'quick_tasks', 'landscape_architect', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 220),
    ('gardener', 'Landscape Designer', 70, '2', 'quick_tasks', 'landscape_designer', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 221),
    ('gardener', 'Head Gardener', 70, '2', 'quick_tasks', 'head_gardener', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 222),
    ('gardener', 'Horticulturist', 70, '2', 'quick_tasks', 'horticulturist', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 223),
    ('gardener', 'Landscape Gardener', 70, '2', 'quick_tasks', 'landscape_gardener', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 224),
    ('gardener', 'General Gardener', 70, '2', 'quick_tasks', 'general_gardener', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 225),
    ('gardener', 'Groundskeeper', 70, '2', 'quick_tasks', 'groundskeeper', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 226),
    ('gardener', 'Kitchen Gardener', 70, '2', 'quick_tasks', 'kitchen_gardener', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 227),
    ('gardener', 'Greenhouse Gardener', 70, '2', 'quick_tasks', 'greenhouse_gardener', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 228),
    ('gardener', 'Water Gardener', 70, '2', 'quick_tasks', 'water_gardener', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 229),
    ('gardener', 'Botanical Garden Specialist', 70, '2', 'quick_tasks', 'botanical_garden_specialist', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 230),
    ('gardener', 'Arborist', 70, '2', 'quick_tasks', 'arborist', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 231),
    ('gardener', 'Nursery Worker', 70, '2', 'quick_tasks', 'nursery_worker', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 232),
    ('gardener', 'Landscape Laborer', 70, '2', 'quick_tasks', 'landscape_laborer', 1, 6, 0.5, 'Garden, grounds, and landscape work.', 233),
    ('housekeeping', 'Executive Housekeeper', 150, '8', 'cooks', 'executive_housekeeper', 4, 12, 1, 'Housekeeping for a home or guest rooms.', 234),
    ('housekeeping', 'Assistant Executive Housekeeper', 150, '8', 'cooks', 'assistant_executive_housekeeper', 4, 12, 1, 'Housekeeping for a home or guest rooms.', 235),
    ('housekeeping', 'Housekeeping Supervisor', 150, '8', 'cooks', 'housekeeping_supervisor', 4, 12, 1, 'Housekeeping for a home or guest rooms.', 236),
    ('housekeeping', 'Guest Room Attendant', 150, '8', 'cooks', 'guest_room_attendant', 4, 12, 1, 'Housekeeping for a home or guest rooms.', 237),
    ('drivers', 'Chauffeur', 80, '4', 'drivers', 'chauffeur', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 238),
    ('drivers', 'Executive Driver', 80, '4', 'drivers', 'executive_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 239),
    ('drivers', 'Rideshare Driver', 80, '4', 'drivers', 'rideshare_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 240),
    ('drivers', 'Taxi Driver', 80, '4', 'drivers', 'taxi_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 241),
    ('drivers', 'Delivery Driver', 80, '4', 'drivers', 'delivery_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 242),
    ('drivers', 'Long-Haul Truck Driver', 80, '4', 'drivers', 'long_haul_truck_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 243),
    ('drivers', 'Short-Haul Truck Driver', 80, '4', 'drivers', 'short_haul_truck_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 244),
    ('drivers', 'Bus Driver', 80, '4', 'drivers', 'bus_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 245),
    ('drivers', 'Shuttle Driver', 80, '4', 'drivers', 'shuttle_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 246),
    ('drivers', 'Valet Driver', 80, '4', 'drivers', 'valet_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 247),
    ('drivers', 'Test Driver', 80, '4', 'drivers', 'test_driver', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 248),
    ('drivers', 'Heavy Equipment Operator', 80, '4', 'drivers', 'heavy_equipment_operator', 1, 12, 1, 'Driving for passengers, deliveries, or equipment.', 249),
    ('nanny', 'Full-Time Live-In Nanny', 50, '4', 'caregiving', 'full_time_live_in_nanny', 2, 10, 1, 'Child care in the home, including nights and travel.', 250),
    ('nanny', 'Full-Time Live-Out Nanny', 50, '4', 'caregiving', 'full_time_live_out_nanny', 2, 10, 1, 'Child care in the home, including nights and travel.', 251),
    ('nanny', 'Shared Nanny', 50, '4', 'caregiving', 'shared_nanny', 2, 10, 1, 'Child care in the home, including nights and travel.', 252),
    ('nanny', 'Part-Time Nanny', 50, '4', 'caregiving', 'part_time_nanny', 2, 10, 1, 'Child care in the home, including nights and travel.', 253),
    ('nanny', 'Nanny-Share Professional', 50, '4', 'caregiving', 'nanny_share_professional', 2, 10, 1, 'Child care in the home, including nights and travel.', 254),
    ('nanny', 'Night Nanny', 50, '4', 'caregiving', 'night_nanny', 2, 10, 1, 'Child care in the home, including nights and travel.', 255),
    ('nanny', 'Newborn Care Specialist', 50, '4', 'caregiving', 'newborn_care_specialist', 2, 10, 1, 'Child care in the home, including nights and travel.', 256),
    ('nanny', 'Travel Nanny', 50, '4', 'caregiving', 'travel_nanny', 2, 10, 1, 'Child care in the home, including nights and travel.', 257),
    ('nanny', 'Au Pair', 50, '4', 'caregiving', 'au_pair', 2, 10, 1, 'Child care in the home, including nights and travel.', 258),
    ('nanny', 'Babysitter', 50, '4', 'caregiving', 'babysitter', 2, 10, 1, 'Child care in the home, including nights and travel.', 259),
    ('nanny', 'Mother''s Helper', 50, '4', 'caregiving', 'mothers_helper', 2, 10, 1, 'Child care in the home, including nights and travel.', 260)
) AS seed(
  category_slug, name, price, duration, service_category, specialty_slug,
  minimum_duration_hours, maximum_duration_hours, duration_increment_hours, description, weight
)
JOIN public.service_categories AS category ON category.slug = seed.category_slug
WHERE NOT EXISTS (
  SELECT 1 FROM public.service_types AS existing WHERE existing.specialty_slug = seed.specialty_slug
);
