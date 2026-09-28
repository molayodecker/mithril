-- AI cleaner matching settings for Mithril rank-cleaners-with-ai.
-- Model/settings are editable in DB; OpenAI calls run in the Phoenix function.
-- Idempotent: safe to run multiple times.

CREATE TABLE IF NOT EXISTS public.platform_config (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  description text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.platform_config
  ADD COLUMN IF NOT EXISTS description text;

ALTER TABLE public.platform_config
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

INSERT INTO public.platform_config (key, value, description)
VALUES (
  'ai_match_settings',
  jsonb_build_object(
    'enabled', true,
    'model', 'gpt-4o-mini',
    'fallback_model', 'gpt-4o-mini',
    'allowed_models', jsonb_build_array('gpt-4o-mini', 'gpt-4o'),
    'temperature', 0.2,
    'max_tokens', 2000,
    'response_format', 'json_object'
  ),
  'AI cleaner matching settings'
)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at = now();

CREATE OR REPLACE FUNCTION public.get_ai_match_settings()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT value
      FROM public.platform_config
      WHERE key = 'ai_match_settings'
      LIMIT 1
    ),
    jsonb_build_object(
      'enabled', false,
      'model', 'gpt-4o-mini',
      'fallback_model', 'gpt-4o-mini',
      'allowed_models', jsonb_build_array('gpt-4o-mini'),
      'temperature', 0.2,
      'max_tokens', 2000,
      'response_format', 'json_object'
    )
  );
$$;
