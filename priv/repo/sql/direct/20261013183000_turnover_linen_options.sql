-- Preserve the exact Airbnb turnover linen instruction selected by the customer.
-- This is additive to the historic three accepted values.
DO $migration$
DECLARE
  constraint_record record;
BEGIN
  IF to_regclass('public.bookings') IS NULL THEN
    RAISE NOTICE 'public.bookings does not exist; skipping turnover linen constraint';
    RETURN;
  END IF;

  FOR constraint_record IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.bookings'::regclass
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) LIKE '%turnover_linen_handling%'
  LOOP
    EXECUTE format('ALTER TABLE public.bookings DROP CONSTRAINT %I', constraint_record.conname);
  END LOOP;

  ALTER TABLE public.bookings
    ADD CONSTRAINT bookings_turnover_linen_handling_check CHECK (
      turnover_linen_handling IS NULL OR turnover_linen_handling IN (
        'clean_linen_provided',
        'launder_on_site',
        'no_linen_change',
        'replace_no_wash',
        'wash_hang_dry',
        'wash_dry_repack_onsite',
        'no_bedding_replace'
      )
    );
END
$migration$;
