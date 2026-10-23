-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
--
-- Direct assignment requests use the same offer alert as marketplace job offers.
-- Android plays the job_offers channel sound. iOS plays the sound filename.
-- new_booking stays the short assignment chime for other booking events.

DROP FUNCTION IF EXISTS public.inbox_notification_android_channel(text);

CREATE OR REPLACE FUNCTION public.inbox_notification_android_channel(
  p_type text,
  p_android_notification_channel_version integer DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_type
    WHEN 'broadcast_assignment_offer' THEN
      CASE
        WHEN coalesce(p_android_notification_channel_version, 0) >= 3 THEN 'job_offers_v3'
        ELSE 'job_offers_v2'
      END
    WHEN 'job_offer' THEN
      CASE
        WHEN coalesce(p_android_notification_channel_version, 0) >= 3 THEN 'job_offers_v3'
        ELSE 'job_offers_v2'
      END
    WHEN 'direct_assignment_offer' THEN
      CASE
        WHEN coalesce(p_android_notification_channel_version, 0) >= 3 THEN 'job_offers_v3'
        ELSE 'job_offers_v2'
      END
    WHEN 'direct_assignment_reminder' THEN
      CASE
        WHEN coalesce(p_android_notification_channel_version, 0) >= 3 THEN 'job_offers_v3'
        ELSE 'job_offers_v2'
      END
    WHEN 'booking_cancelled' THEN 'booking_cancellations'
    WHEN 'booking_rescheduled' THEN 'booking_updates'
    WHEN 'review_request' THEN 'booking_updates'
    WHEN 'wallet_credited' THEN 'booking_updates'
    WHEN 'unassigned_booking_escalated' THEN 'booking_cancellations'
    WHEN 'new_message' THEN 'messages'
    WHEN 'cleaner_en_route' THEN 'cleaner_milestones'
    WHEN 'cleaner_arrived' THEN 'cleaner_milestones'
    ELSE 'booking_updates'
  END;
$$;

COMMENT ON FUNCTION public.inbox_notification_android_channel(text, integer) IS
  'Expo Android channel for inbox pushes. Worker requests use job_offers so the offer alert plays. _v3 only when the device reported channel version >= 3.';

CREATE OR REPLACE FUNCTION public.inbox_notification_android_sound(p_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_type
    WHEN 'broadcast_assignment_offer' THEN 'instaclean_job_offer.wav'
    WHEN 'job_offer' THEN 'instaclean_job_offer.wav'
    WHEN 'direct_assignment_offer' THEN 'instaclean_job_offer.wav'
    WHEN 'direct_assignment_reminder' THEN 'instaclean_job_offer.wav'
    ELSE 'default'
  END;
$$;

COMMENT ON FUNCTION public.inbox_notification_android_sound IS
  'Expo push sound filename. Worker requests use the offer alert on iOS. Android mainly uses the channel sound.';
