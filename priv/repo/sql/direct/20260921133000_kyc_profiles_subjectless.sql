DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'kyc_profiles'
      AND column_name = 'subject_type'
  ) THEN
    ALTER TABLE public.kyc_profiles
      ALTER COLUMN subject_type DROP DEFAULT,
      ALTER COLUMN subject_type DROP NOT NULL;
  END IF;
END
$$;
