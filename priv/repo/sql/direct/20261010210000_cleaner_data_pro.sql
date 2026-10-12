-- Customer-facing PRO badge / PRO-only browse filter.
-- Independent of cleaner_data.verified (identity/KYC). Defaults off.

ALTER TABLE public.cleaner_data
  ADD COLUMN IF NOT EXISTS pro boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.cleaner_data.pro IS
  'When true, the worker is shown as PRO on customer browse cards and included in the PRO-only filter.';
