-- Courses assigned to a worker when Instaclean flags performance
-- or a team lead recommends training. The worker app only reads and completes
-- rows for the signed-in worker. Course copy lives in Mithril.WorkerTraining.

CREATE TABLE IF NOT EXISTS public.worker_training_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  course_key text NOT NULL CHECK (
    course_key IN ('job-quality', 'punctuality', 'customer-care', 'safety')
  ),
  reason text NOT NULL CHECK (reason IN ('performance', 'employer')),
  status text NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned', 'completed')),
  health_case_id uuid,
  assigned_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

COMMENT ON TABLE public.worker_training_assignments IS
  'Training assigned to a worker. reason performance comes from a cleaner health case. reason employer comes from the worker''s team lead.';

COMMENT ON COLUMN public.worker_training_assignments.health_case_id IS
  'cleaner_operations_cases.id when Instaclean assigned the course from a health case.';

CREATE INDEX IF NOT EXISTS worker_training_assignments_worker_user_id_idx
  ON public.worker_training_assignments (worker_user_id, assigned_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS worker_training_assignments_open_course_idx
  ON public.worker_training_assignments (worker_user_id, course_key)
  WHERE status = 'assigned';
