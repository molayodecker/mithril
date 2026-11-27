-- Ready Stripe attempts were stored with expires_at = infinity so they would
-- not expire while the customer finished checkout. Postgrex raises on that
-- value, and reserve_booking_payment_attempt returns the column, so the next
-- checkout becomes an Internal Server Error.
-- NULL does not satisfy `expires_at <= now()`, so a ready attempt still does
-- not expire. Safe to run again.

UPDATE public.payment_attempts
SET expires_at = NULL,
    updated_at = now()
WHERE expires_at = 'infinity'::timestamptz;
