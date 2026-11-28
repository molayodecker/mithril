-- Inbox rows the mobile app reads for the message list and the unread badge.
-- Unread messages are those sent by the other person and not yet marked read.

CREATE OR REPLACE VIEW public.conversation_list
WITH (security_invoker = true) AS
SELECT
  c.id,
  c.customer_id,
  c.cleaner_id,
  c.booking_id,
  c.last_message_at,
  c.metadata,
  c.created_at,
  c.updated_at,
  customer.fullname AS customer_name,
  customer.avatar_url AS customer_avatar,
  cleaner.fullname AS cleaner_name,
  cleaner.avatar_url AS cleaner_avatar,
  b.scheduled_date AS booking_scheduled_date,
  b.scheduled_time::text AS booking_scheduled_time,
  b.title AS booking_title,
  (
    SELECT m.content
    FROM public.messages m
    WHERE m.conversation_id = c.id
    ORDER BY m.created_at DESC
    LIMIT 1
  ) AS last_message_text,
  (
    SELECT count(*)::integer
    FROM public.messages m
    WHERE m.conversation_id = c.id
      AND m.read_at IS NULL
      AND m.sender_id IS DISTINCT FROM auth.uid()
  ) AS unread_count
FROM public.conversations c
LEFT JOIN public.profiles customer ON customer.id = c.customer_id
LEFT JOIN public.profiles cleaner ON cleaner.id = c.cleaner_id
LEFT JOIN public.bookings b ON b.id = c.booking_id;

DO $$
BEGIN
  GRANT SELECT ON public.conversation_list TO authenticated;
EXCEPTION
  WHEN undefined_object OR insufficient_privilege THEN
    NULL;
END
$$;
