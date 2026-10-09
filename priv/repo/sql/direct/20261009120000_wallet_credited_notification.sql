-- Cleaner wallet credits use the inbox type wallet_credited.
-- Mithril writes the inbox row and queues WhatsApp. This file only adds the
-- type and the Android channel the existing inbox push trigger expects.
-- Withdrawal refunds are not this type.

ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'wallet_credited';

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
        WHEN coalesce(p_android_notification_channel_version, 0) >= 3 THEN 'new_booking_v3'
        ELSE 'new_booking_v2'
      END
    WHEN 'direct_assignment_reminder' THEN
      CASE
        WHEN coalesce(p_android_notification_channel_version, 0) >= 3 THEN 'new_booking_v3'
        ELSE 'new_booking_v2'
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
  'Expo Android channel for inbox-triggered pushes; wallet_credited and review_request use booking_updates. Job alerts use _v3 only when device reported channel version >= 3; otherwise _v2.';

-- Initialize the cutoff when the migration is applied, so historical wallet
-- credits cannot trigger newly-enabled customer-facing notifications.
CREATE TABLE IF NOT EXISTS public.wallet_credit_notification_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  activated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.wallet_credit_notification_settings (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.wallet_credit_whatsapp_delivery (
  transaction_id uuid PRIMARY KEY,
  sent_at timestamptz,
  next_attempt_at timestamptz NOT NULL DEFAULT now()
);
