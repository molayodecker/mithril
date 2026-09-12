-- Candidate video introductions for Instaclean Direct.
--
-- Videos remain hosted outside Postgres. Mithril stores only HTTPS playback
-- metadata and controls which shortlisted customers may read it.

ALTER TABLE public.placement_candidate_profiles
  ADD COLUMN IF NOT EXISTS intro_video_url text,
  ADD COLUMN IF NOT EXISTS intro_video_thumbnail_url text,
  ADD COLUMN IF NOT EXISTS intro_video_title text;

ALTER TABLE public.placement_candidate_profiles
  DROP CONSTRAINT IF EXISTS placement_candidate_profiles_intro_video_url_https_check;

ALTER TABLE public.placement_candidate_profiles
  ADD CONSTRAINT placement_candidate_profiles_intro_video_url_https_check CHECK (
    intro_video_url IS NULL OR intro_video_url ~ '^https://'
  );

ALTER TABLE public.placement_candidate_profiles
  DROP CONSTRAINT IF EXISTS placement_candidate_profiles_intro_video_thumbnail_https_check;

ALTER TABLE public.placement_candidate_profiles
  ADD CONSTRAINT placement_candidate_profiles_intro_video_thumbnail_https_check CHECK (
    intro_video_thumbnail_url IS NULL OR intro_video_thumbnail_url ~ '^https://'
  );

ALTER TABLE public.placement_candidate_profiles
  DROP CONSTRAINT IF EXISTS placement_candidate_profiles_intro_video_title_length_check;

ALTER TABLE public.placement_candidate_profiles
  ADD CONSTRAINT placement_candidate_profiles_intro_video_title_length_check CHECK (
    intro_video_title IS NULL OR char_length(intro_video_title) <= 120
  );
