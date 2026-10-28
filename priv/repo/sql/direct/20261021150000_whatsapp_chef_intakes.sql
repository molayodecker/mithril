-- WhatsApp chef enquiry conversation state. Idempotent.
-- Matches priv/repo/migrations/20261021150000_create_whatsapp_chef_intakes.exs
-- so Fly deploys apply it (Ecto migrations are not a release_command).

CREATE TABLE IF NOT EXISTS public.whatsapp_chef_intakes (
  phone text PRIMARY KEY,
  step integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'in_progress',
  answers jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_message_sid text,
  submitted_at timestamp without time zone,
  inserted_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL
);

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chef_intake_status_check'
      AND conrelid = 'public.whatsapp_chef_intakes'::regclass
  ) THEN
    ALTER TABLE public.whatsapp_chef_intakes
      ADD CONSTRAINT chef_intake_status_check
      CHECK (status IN ('in_progress', 'confirm', 'completed', 'paused'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chef_intake_step_check'
      AND conrelid = 'public.whatsapp_chef_intakes'::regclass
  ) THEN
    ALTER TABLE public.whatsapp_chef_intakes
      ADD CONSTRAINT chef_intake_step_check
      CHECK (step BETWEEN 0 AND 8);
  END IF;
END
$migration$;

CREATE INDEX IF NOT EXISTS whatsapp_chef_intakes_status_updated_at_index
  ON public.whatsapp_chef_intakes (status, updated_at);

CREATE TABLE IF NOT EXISTS public.whatsapp_chef_processed_messages (
  message_sid text PRIMARY KEY,
  phone text NOT NULL,
  inserted_at timestamp without time zone NOT NULL
);

CREATE INDEX IF NOT EXISTS whatsapp_chef_processed_messages_phone_index
  ON public.whatsapp_chef_processed_messages (phone);

CREATE TABLE IF NOT EXISTS public.whatsapp_chef_completed_enquiries (
  id bigserial PRIMARY KEY,
  phone text NOT NULL,
  answers jsonb NOT NULL,
  submitted_at timestamp without time zone NOT NULL,
  inserted_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL
);

CREATE INDEX IF NOT EXISTS whatsapp_chef_completed_enquiries_submitted_at_index
  ON public.whatsapp_chef_completed_enquiries (submitted_at);
