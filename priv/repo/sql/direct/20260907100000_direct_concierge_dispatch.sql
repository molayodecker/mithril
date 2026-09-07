-- Instaclean Direct concierge/dispatch foundation.
--
-- Supports customer urgent-help and replacement requests plus an auditable
-- provenance record for bookings created by Instaclean operations on behalf of
-- a customer. "Urgent help" is intentionally non-medical; Direct must not
-- represent itself as an emergency medical service.

CREATE TABLE IF NOT EXISTS public.direct_service_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind text NOT NULL
    CHECK (kind IN ('urgent_help', 'replacement')),
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'triaging', 'matching', 'assigned', 'resolved', 'cancelled')),
  priority text NOT NULL DEFAULT 'standard'
    CHECK (priority IN ('urgent', 'same_day', 'standard')),
  role text
    CHECK (
      role IS NULL OR role IN (
        'househelp', 'nanny', 'cleaner', 'elder_caregiver',
        'cook', 'driver', 'gardener'
      )
    ),
  requested_start_at timestamptz,
  duration_hours numeric
    CHECK (duration_hours IS NULL OR (duration_hours > 0 AND duration_hours <= 24)),
  household_address_snapshot text NOT NULL CHECK (btrim(household_address_snapshot) <> ''),
  related_booking_id uuid REFERENCES public.bookings(id) ON DELETE SET NULL,
  requirements jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(requirements) = 'object'),
  notes text,
  admin_note text,
  created_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  assigned_worker_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_service_requests_kind_shape_check CHECK (
    (
      kind = 'urgent_help'
      AND role IS NOT NULL
      AND related_booking_id IS NULL
    ) OR (
      kind = 'replacement'
      AND related_booking_id IS NOT NULL
    )
  )
);

CREATE INDEX IF NOT EXISTS direct_service_requests_customer_idx
  ON public.direct_service_requests (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS direct_service_requests_dispatch_idx
  ON public.direct_service_requests (status, priority, created_at ASC);
CREATE INDEX IF NOT EXISTS direct_service_requests_assigned_worker_idx
  ON public.direct_service_requests (assigned_worker_user_id, status)
  WHERE assigned_worker_user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS direct_service_requests_active_replacement_uniq
  ON public.direct_service_requests (related_booking_id)
  WHERE kind = 'replacement'
    AND status IN ('submitted', 'triaging', 'matching', 'assigned');

DROP TRIGGER IF EXISTS direct_service_requests_set_updated_at
  ON public.direct_service_requests;
CREATE TRIGGER direct_service_requests_set_updated_at
BEFORE UPDATE ON public.direct_service_requests
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.direct_booking_origins (
  booking_id uuid PRIMARY KEY REFERENCES public.bookings(id) ON DELETE CASCADE,
  customer_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  source text NOT NULL CHECK (source IN ('admin', 'phone', 'whatsapp')),
  consent_confirmed boolean NOT NULL DEFAULT false,
  admin_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_booking_origins_consent_check CHECK (consent_confirmed = true)
);

CREATE INDEX IF NOT EXISTS direct_booking_origins_creator_idx
  ON public.direct_booking_origins (created_by_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS direct_booking_origins_customer_idx
  ON public.direct_booking_origins (customer_id, created_at DESC);
