-- Book Now gates for the cooks and drivers categories.
-- Same shape as is_airbnb_catalog_visible / is_quick_tasks_catalog_visible.
-- Missing rows stay hidden: is_app_feature_enabled defaults to false.

CREATE OR REPLACE FUNCTION public.is_cooks_catalog_visible()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_app_feature_enabled('COOKS_BOOK_NOW', 'production');
$$;

CREATE OR REPLACE FUNCTION public.is_drivers_catalog_visible()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_app_feature_enabled('DRIVERS_BOOK_NOW', 'production');
$$;

INSERT INTO public.app_feature_flags (key, channel, enabled)
VALUES
  ('COOKS_BOOK_NOW', 'production', false),
  ('COOKS_BOOK_NOW', 'preview', false),
  ('DRIVERS_BOOK_NOW', 'production', false),
  ('DRIVERS_BOOK_NOW', 'preview', false)
ON CONFLICT (key, channel) DO NOTHING;

COMMENT ON FUNCTION public.is_cooks_catalog_visible() IS
  'True when COOKS_BOOK_NOW is enabled for the production channel.';

COMMENT ON FUNCTION public.is_drivers_catalog_visible() IS
  'True when DRIVERS_BOOK_NOW is enabled for the production channel.';
