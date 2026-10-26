-- Applied by scripts/apply_direct_schema.sh with the rest of priv/repo/sql/direct.
--
-- The payment trigger inserts a worker request without an audience. The open
-- app loops the offer alert when the push says audience worker.
-- Channel and sound stay in 20261023160000_worker_request_offer_alert_sound.sql,
-- which also keeps wallet_credited on booking_updates.

CREATE OR REPLACE FUNCTION public.queue_inbox_notification_push(
  p_user_id uuid,
  p_title text,
  p_body text,
  p_type text,
  p_data jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_title text;
  v_body text;
  v_type text;
  v_channel text;
  v_sound text;
  v_interruption text;
  v_badge integer := 0;
  v_messages jsonb := '[]'::jsonb;
  v_token text;
  v_channel_version integer;
  v_request_id bigint;
  v_push_data jsonb;
  v_message jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  v_title := coalesce(nullif(trim(p_title), ''), 'Instaclean');
  v_body := coalesce(nullif(trim(p_body), ''), 'You have a new notification.');
  v_type := coalesce(nullif(trim(p_type), ''), 'unknown');
  v_sound := public.inbox_notification_android_sound(v_type);

  v_push_data := coalesce(p_data, '{}'::jsonb);
  IF NOT (v_push_data ? 'type') THEN
    v_push_data := v_push_data || jsonb_build_object('type', v_type);
  END IF;
  IF (v_push_data ? 'booking_id') AND NOT (v_push_data ? 'bookingId') THEN
    v_push_data := v_push_data || jsonb_build_object('bookingId', v_push_data->>'booking_id');
  END IF;
  -- Worker requests ring even if the app is currently showing the customer UI.
  IF v_type IN (
    'job_offer',
    'broadcast_assignment_offer',
    'direct_assignment_offer',
    'direct_assignment_reminder'
  ) AND NOT (v_push_data ? 'audience') THEN
    v_push_data := v_push_data || jsonb_build_object('audience', 'worker');
  END IF;

  v_interruption := public.inbox_notification_interruption_level(v_type);

  SELECT count(*)::integer
  INTO v_badge
  FROM public.notifications
  WHERE user_id = p_user_id
    AND read = false;

  v_badge := least(greatest(coalesce(v_badge, 0), 1), 999);

  FOR v_token, v_channel_version IN
    SELECT t.token, max(t.android_notification_channel_version)::integer
    FROM (
      SELECT dt.token, dt.android_notification_channel_version
      FROM public.device_tokens dt
      WHERE dt.user_id = p_user_id
        AND dt.token ~ '^(Expo(nent)?PushToken)\[.+\]$'
      UNION ALL
      SELECT cd.expo_push_token AS token, NULL::integer AS android_notification_channel_version
      FROM public.cleaner_devices cd
      WHERE cd.cleaner_id = p_user_id
        AND cd.expo_push_token ~ '^(Expo(nent)?PushToken)\[.+\]$'
    ) t
    WHERE t.token IS NOT NULL
    GROUP BY t.token
  LOOP
    v_channel := public.inbox_notification_android_channel(v_type, v_channel_version);
    v_message := jsonb_build_object(
      'to', v_token,
      'title', v_title,
      'body', v_body,
      'sound', v_sound,
      'priority', 'high',
      'channelId', v_channel,
      'badge', v_badge,
      'data', v_push_data
    );
    IF v_interruption IS NOT NULL THEN
      v_message := v_message || jsonb_build_object('interruptionLevel', v_interruption);
    END IF;
    v_messages := v_messages || jsonb_build_array(v_message);
  END LOOP;

  IF jsonb_array_length(v_messages) = 0 THEN
    RAISE LOG 'queue_inbox_notification_push: no push tokens for user % type %', p_user_id, v_type;
    RETURN;
  END IF;

  SELECT net.http_post(
    url := 'https://exp.host/--/api/v2/push/send',
    body := v_messages,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 30000
  )
  INTO v_request_id;

  RAISE LOG 'queue_inbox_notification_push queued expo request %, user %, type %, devices %',
    v_request_id, p_user_id, v_type, jsonb_array_length(v_messages);
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'queue_inbox_notification_push failed user % type %: %',
      p_user_id, v_type, SQLERRM;
END;
$$;

COMMENT ON FUNCTION public.queue_inbox_notification_push(uuid, text, text, text, jsonb) IS
  'Queues an Expo push for an inbox row. Worker requests without an audience are marked worker so the offer alert rings.';
