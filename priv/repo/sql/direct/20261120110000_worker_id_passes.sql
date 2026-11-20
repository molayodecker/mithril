-- Apple Wallet registrations for the public worker ID.
-- The pass file is rebuilt from the worker's current status. A suspended
-- worker's pass is voided and registered phones are asked to refresh it.
-- Safe to run again.

CREATE TABLE IF NOT EXISTS public.worker_id_passes (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  serial_number text NOT NULL UNIQUE,
  authentication_token text NOT NULL,
  voided boolean NOT NULL DEFAULT false,
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
