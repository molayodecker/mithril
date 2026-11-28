-- Booking write guards call auth.role(). Supabase used to provide it.
-- A Mithril server session sets the user id and does not set a JWT role,
-- so this returns null and those guards allow the server write.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $function$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  )
$function$;
