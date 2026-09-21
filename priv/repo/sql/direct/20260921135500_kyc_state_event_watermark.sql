DO $$
BEGIN
  IF to_regclass('public.kyc_profiles') IS NOT NULL THEN
    ALTER TABLE public.kyc_profiles
      ADD COLUMN IF NOT EXISTS last_state_event_created_at_ms bigint;

    UPDATE public.kyc_profiles
    SET last_state_event_created_at_ms = last_event_created_at_ms
    WHERE last_state_event_created_at_ms IS NULL
      AND last_event_created_at_ms IS NOT NULL
      AND lower(regexp_replace(COALESCE(last_event_type, ''), '[^a-zA-Z0-9]', '', 'g')) IN (
        'applicantreviewed',
        'applicantactionreviewed',
        'applicantpending',
        'applicantonhold',
        'applicantprechecked',
        'applicantawaitinguser',
        'applicantawaitingservice',
        'applicantactionpending',
        'applicantactiononhold',
        'applicantcreated',
        'applicantactivated',
        'applicantdeactivated',
        'applicantdeleted',
        'applicantreset',
        'applicantpersonaldatadeleted'
      );
  END IF;
END
$$;
