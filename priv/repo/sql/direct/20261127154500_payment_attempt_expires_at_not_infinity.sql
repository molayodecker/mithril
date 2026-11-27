-- Ready Stripe attempts were stored with expires_at = infinity so they would
-- not expire while the customer finished checkout. Postgrex raises on that
-- value, and reserve_booking_payment_attempt returns the column, so the next
-- checkout becomes an Internal Server Error.
-- NULL does not satisfy `expires_at <= now()`, so a ready attempt still does
-- not expire.
-- Older databases declare expires_at NOT NULL. Drop that constraint before
-- replacing infinity, or the update fails and a new ready attempt cannot be
-- saved. Safe to run again.

ALTER TABLE public.payment_attempts
  ALTER COLUMN expires_at DROP NOT NULL;

-- %%

UPDATE public.payment_attempts
SET expires_at = NULL,
    updated_at = now()
WHERE expires_at = 'infinity'::timestamptz;
