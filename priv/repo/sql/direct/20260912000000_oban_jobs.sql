-- Oban 2.24 tables for Direct visit reminders.
-- Idempotent. COMMENT version 14 matches Oban.Migration current_version.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'oban_job_state'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.oban_job_state AS ENUM (
      'available',
      'scheduled',
      'executing',
      'retryable',
      'completed',
      'discarded',
      'cancelled'
    );
  END IF;
END$$;

ALTER TYPE public.oban_job_state ADD VALUE IF NOT EXISTS 'cancelled';
ALTER TYPE public.oban_job_state ADD VALUE IF NOT EXISTS 'suspended' BEFORE 'scheduled';

CREATE TABLE IF NOT EXISTS public.oban_jobs (
  id bigserial PRIMARY KEY,
  state public.oban_job_state NOT NULL DEFAULT 'available',
  queue text NOT NULL DEFAULT 'default',
  worker text NOT NULL,
  args jsonb NOT NULL DEFAULT '{}'::jsonb,
  errors jsonb[] NOT NULL DEFAULT ARRAY[]::jsonb[],
  attempt integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 20,
  inserted_at timestamptz NOT NULL DEFAULT timezone('UTC', now()),
  scheduled_at timestamptz NOT NULL DEFAULT timezone('UTC', now()),
  attempted_at timestamptz,
  completed_at timestamptz,
  attempted_by text[],
  discarded_at timestamptz,
  priority integer NOT NULL DEFAULT 0,
  tags text[] NOT NULL DEFAULT ARRAY[]::text[],
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  cancelled_at timestamptz,
  CONSTRAINT worker_length CHECK (char_length(worker) > 0 AND char_length(worker) < 128),
  CONSTRAINT queue_length CHECK (char_length(queue) > 0 AND char_length(queue) < 128),
  CONSTRAINT non_negative_priority CHECK (priority >= 0),
  CONSTRAINT positive_max_attempts CHECK (max_attempts > 0),
  CONSTRAINT attempt_range CHECK (attempt BETWEEN 0 AND max_attempts)
);

CREATE INDEX IF NOT EXISTS oban_jobs_state_queue_priority_scheduled_at_id_index
  ON public.oban_jobs (state, queue, priority, scheduled_at, id);
CREATE INDEX IF NOT EXISTS oban_jobs_args_index ON public.oban_jobs USING gin (args);
CREATE INDEX IF NOT EXISTS oban_jobs_meta_index ON public.oban_jobs USING gin (meta);
CREATE INDEX IF NOT EXISTS oban_jobs_state_cancelled_at_index
  ON public.oban_jobs (state, cancelled_at);
CREATE INDEX IF NOT EXISTS oban_jobs_state_discarded_at_index
  ON public.oban_jobs (state, discarded_at);

CREATE TABLE IF NOT EXISTS public.oban_peers (
  name text PRIMARY KEY,
  node text NOT NULL,
  started_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);

ALTER TABLE public.oban_peers SET UNLOGGED;

COMMENT ON TABLE public.oban_jobs IS '14';
