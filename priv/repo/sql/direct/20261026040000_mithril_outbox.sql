-- Inbox pushes, new-message alerts, and Paystack customer creation
-- are queued here and delivered by Mithril. No outbound HTTP from Postgres.

CREATE TABLE IF NOT EXISTS public.mithril_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  dedupe_key text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  available_at timestamptz NOT NULL DEFAULT now(),
  claimed_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  CONSTRAINT mithril_outbox_kind_dedupe UNIQUE (kind, dedupe_key),
  CONSTRAINT mithril_outbox_status_check
    CHECK (status IN ('pending', 'sending', 'sent', 'failed'))
);

CREATE INDEX IF NOT EXISTS mithril_outbox_pending_idx
  ON public.mithril_outbox (available_at, inserted_at)
  WHERE status = 'pending';

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
SET search_path = public
AS $$
DECLARE
  v_title text;
  v_body text;
  v_type text;
  v_push_data jsonb;
  v_dedupe text;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  v_title := coalesce(nullif(trim(p_title), ''), 'Instaclean');
  v_body := coalesce(nullif(trim(p_body), ''), 'You have a new notification.');
  v_type := coalesce(nullif(trim(p_type), ''), 'unknown');

  v_push_data := coalesce(p_data, '{}'::jsonb);
  IF NOT (v_push_data ? 'type') THEN
    v_push_data := v_push_data || jsonb_build_object('type', v_type);
  END IF;
  IF (v_push_data ? 'booking_id') AND NOT (v_push_data ? 'bookingId') THEN
    v_push_data := v_push_data || jsonb_build_object('bookingId', v_push_data->>'booking_id');
  END IF;
  -- `worker` is the current audience. `cleaner` remains accepted by the app.
  IF v_type IN (
    'job_offer',
    'broadcast_assignment_offer',
    'direct_assignment_offer',
    'direct_assignment_reminder'
  ) AND NOT (v_push_data ? 'audience') THEN
    v_push_data := v_push_data || jsonb_build_object('audience', 'worker');
  END IF;

  v_dedupe := coalesce(
    nullif(v_push_data->>'notification_id', ''),
    md5(p_user_id::text || '|' || v_type || '|' || v_push_data::text || '|' || v_title)
  );

  INSERT INTO public.mithril_outbox (kind, dedupe_key, payload)
  VALUES (
    'inbox_push',
    v_dedupe,
    jsonb_build_object(
      'user_id', p_user_id,
      'title', v_title,
      'body', v_body,
      'type', v_type,
      'data', v_push_data
    )
  )
  ON CONFLICT (kind, dedupe_key) DO UPDATE
  SET status = 'pending',
      attempts = 0,
      last_error = NULL,
      available_at = now(),
      claimed_at = NULL
  WHERE public.mithril_outbox.status = 'failed';
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_inbox_notification_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type::text IN (
    'new_message',
    'payment_received',
    'cleaner_en_route',
    'cleaner_arrived',
    'review_request'
  ) THEN
    RETURN NEW;
  END IF;

  PERFORM public.queue_inbox_notification_push(
    NEW.user_id,
    NEW.title,
    NEW.message,
    NEW.type::text,
    coalesce(NEW.data, '{}'::jsonb) || jsonb_build_object('notification_id', NEW.id)
  );

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'notify_inbox_notification_push failed for notification %: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_new_message_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.mithril_outbox (kind, dedupe_key, payload)
  VALUES (
    'new_message',
    NEW.id::text,
    jsonb_build_object('message_id', NEW.id)
  )
  ON CONFLICT (kind, dedupe_key) DO UPDATE
  SET status = 'pending',
      attempts = 0,
      last_error = NULL,
      available_at = now(),
      claimed_at = NULL
  WHERE public.mithril_outbox.status = 'failed';

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'notify_new_message enqueue failed for message %: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.trigger_paystack_on_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  IF NEW.verified IS TRUE
     AND (TG_OP = 'INSERT' OR OLD.verified IS DISTINCT FROM TRUE)
  THEN
    v_user_id := CASE
      WHEN to_jsonb(NEW) ? 'user_id' AND nullif(to_jsonb(NEW)->>'user_id', '') IS NOT NULL
        THEN (to_jsonb(NEW)->>'user_id')::uuid
      WHEN to_jsonb(NEW) ? 'id' AND nullif(to_jsonb(NEW)->>'id', '') IS NOT NULL
        THEN (to_jsonb(NEW)->>'id')::uuid
      ELSE NULL
    END;

    IF v_user_id IS NOT NULL THEN
      INSERT INTO public.mithril_outbox (kind, dedupe_key, payload)
      VALUES (
        'paystack_customer',
        v_user_id::text,
        jsonb_build_object('user_id', v_user_id)
      )
      ON CONFLICT (kind, dedupe_key) DO UPDATE
      SET status = 'pending',
          attempts = 0,
          last_error = NULL,
          available_at = now(),
          claimed_at = NULL
      WHERE public.mithril_outbox.status = 'failed';
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'paystack customer enqueue failed: %', SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_paystack_customer_on_verification ON public.cleaner_data;

CREATE TRIGGER trg_enqueue_paystack_customer_on_verification
  AFTER INSERT OR UPDATE OF verified ON public.cleaner_data
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_paystack_on_approval();
