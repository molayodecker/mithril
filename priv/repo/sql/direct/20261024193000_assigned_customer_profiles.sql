-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
--
-- Mobile profile selects are forced to the signed-in user, so an assigned
-- cleaner cannot load the customer from the profiles table. This returns only
-- the name and avatar for customers who share a booking with the caller.

CREATE OR REPLACE FUNCTION public.get_assigned_customer_profiles(p_customer_ids uuid[])
RETURNS TABLE (
  id uuid,
  fullname text,
  firstname text,
  lastname text,
  avatar_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
  SELECT DISTINCT
    p.id,
    p.fullname,
    p.firstname,
    p.lastname,
    p.avatar_url
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
    AND p.id = ANY((COALESCE(p_customer_ids, ARRAY[]::uuid[]))[1:100])
    AND p.deleted_at IS NULL
    AND p.deactivated_at IS NULL
    AND COALESCE(p.deletion_status::text, 'none') NOT IN ('scheduled', 'processing', 'completed')
    AND EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.customer_id = p.id
        AND (
          b.cleaner_id = auth.uid()
          OR b.direct_assigned_cleaner_id = auth.uid()
        )
    );
$$;

COMMENT ON FUNCTION public.get_assigned_customer_profiles(uuid[]) IS
  'Name and avatar for customers the caller is assigned to clean for. Omits address and other private profile fields. Empty when the caller has no booking relationship.';
