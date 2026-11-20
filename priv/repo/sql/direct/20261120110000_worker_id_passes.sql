-- Apple Wallet registrations for the public worker ID.
-- The pass file is rebuilt from the worker's current status. A suspended
-- worker's pass is voided and registered phones are asked to refresh it.
-- Safe to run again.

CREATE TABLE IF NOT EXISTS public.worker_id_passes (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  serial_number text NOT NULL UNIQUE,
  authentication_token text NOT NULL,
  voided boolean NOT NULL DEFAULT false,
  push_pending boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.worker_id_passes IS
  'One Apple Wallet pass per worker. serial_number is the booking slug. authentication_token is the pass web-service secret.';

CREATE TABLE IF NOT EXISTS public.worker_id_pass_registrations (
  device_library_identifier text NOT NULL,
  pass_type_identifier text NOT NULL,
  serial_number text NOT NULL REFERENCES public.worker_id_passes(serial_number) ON DELETE CASCADE,
  push_token text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_library_identifier, pass_type_identifier, serial_number)
);

CREATE INDEX IF NOT EXISTS worker_id_pass_registrations_serial_idx
  ON public.worker_id_pass_registrations (serial_number);

CREATE TABLE IF NOT EXISTS public.worker_id_pass_downloads (
  token_hash text PRIMARY KEY,
  serial_number text NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS worker_id_pass_downloads_expires_idx
  ON public.worker_id_pass_downloads (expires_at);

-- Existing deployments can replay this script without losing registrations.
ALTER TABLE public.worker_id_passes
  ADD COLUMN IF NOT EXISTS push_pending boolean NOT NULL DEFAULT false;

-- Status changes are durable even if the API process is down. The minute
-- sweep delivers APNs notifications and keeps failed pushes pending.
CREATE OR REPLACE FUNCTION public.queue_worker_id_status_refresh()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.worker_id_passes p
    SET voided = (
          EXISTS (SELECT 1 FROM public.users u
                  WHERE u.id = p.user_id AND u.status::text = 'suspended')
          OR EXISTS (SELECT 1 FROM public.cleaner_data cd
                     WHERE cd.user_id = p.user_id AND cd.status::text = 'suspended')
        ),
        push_pending = true,
        updated_at = GREATEST(clock_timestamp(), p.updated_at + interval '1 microsecond')
    WHERE p.user_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

-- Cleaner records use user_id, not id.
CREATE OR REPLACE FUNCTION public.queue_cleaner_worker_id_status_refresh()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.worker_id_passes p
    SET voided = (
          EXISTS (SELECT 1 FROM public.users u
                  WHERE u.id = p.user_id AND u.status::text = 'suspended')
          OR NEW.status::text = 'suspended'
        ),
        push_pending = true,
        updated_at = GREATEST(clock_timestamp(), p.updated_at + interval '1 microsecond')
    WHERE p.user_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS worker_id_users_status_refresh ON public.users;
CREATE TRIGGER worker_id_users_status_refresh
AFTER UPDATE OF status ON public.users
FOR EACH ROW EXECUTE FUNCTION public.queue_worker_id_status_refresh();

DROP TRIGGER IF EXISTS worker_id_cleaner_status_refresh ON public.cleaner_data;
CREATE TRIGGER worker_id_cleaner_status_refresh
AFTER UPDATE OF status ON public.cleaner_data
FOR EACH ROW EXECUTE FUNCTION public.queue_cleaner_worker_id_status_refresh();
